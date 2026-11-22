#!/usr/bin/env julia
# SPDX-FileCopyrightText: 2025 The Jeff Paradox Collaboration
# SPDX-License-Identifier: MPL-2.0
#
# Thinking A/B/C experiment on Claude Sonnet 5.5, default scenario, new games.
#   A: no thinking anywhere.  B: thinking for both personas and the GM.
#   C: 1 persona thinks (C1 alpha, C2 beta), the GM does not.
# All games advance 1 turn per round, in parallel, so they stay the same length.
# The run stops before the round that could pass the budget.
#
# Usage: julia --project=engine engine/scripts/run_experiment.jl <out_dir> <budget_usd> [max_rounds]

using JeffEngine, YAML, JSON3, Printf, Dates

const ROOT = normpath(joinpath(@__DIR__, "..", ".."))
const MODEL = "claude-sonnet-5-5"
const ON = (thinking = "default", max_tokens = 4096)   # model default: adaptive thinking
const OFF = (thinking = "off", max_tokens = 1024)
# game id => (alpha, beta, gm)
const GAMES = ["A1" => (OFF, OFF, OFF), "A2" => (OFF, OFF, OFF),
               "B1" => (ON, ON, ON),    "B2" => (ON, ON, ON),
               "C1" => (ON, OFF, OFF),  "C2" => (OFF, ON, OFF)]

mutable struct Run
    id::String
    dir::String
    game::GameState
    nodes::Dict{Symbol,NodeState}
    error::String
end

function setup(out::String, id::String, (a, b, gm))::Run
    dir = joinpath(out, id)
    for (node, s) in (("alpha", a), ("beta", b))
        y = YAML.load_file(joinpath(ROOT, "node-$node", "data", "node_state.yml"))
        merge!(y["llm"], Dict("provider" => "anthropic", "model" => MODEL,
                              "thinking" => s.thinking, "max_tokens" => s.max_tokens))
        mkpath(joinpath(dir, "node-$node", "data"))
        YAML.write_file(joinpath(dir, "node-$node", "data", "node_state.yml"), y)
    end
    game = initialise_game_state(joinpath(dir, "no-such-config.yml"))  # engine defaults
    merge!(game.config, Dict("gm_model" => MODEL, "gm_thinking" => gm.thinking, "gm_max_tokens" => gm.max_tokens))
    mkpath(joinpath(dir, "turns"))
    open(joinpath(dir, "usage.csv"), "w") do f
        println(f, "turn,node,input_tokens,output_tokens,cost_usd_cumulative")
    end
    Run(id, dir, game, JeffEngine.load_nodes(dir), "")
end

function play_turn!(r::Run)
    task_local_storage(:jeff_game, r.id) do
        node = String(r.game.current_node)
        try
            result = execute_turn(r.game, r.nodes)
            save_turn_to_markdown(result, joinpath(r.dir, "turns", @sprintf("%04d-%s.md", result.turn_number, node)))
            u = get(JeffEngine.USAGE, (r.id, MODEL), [0, 0])
            open(joinpath(r.dir, "usage.csv"), "a") do f
                @printf(f, "%d,%s,%d,%d,%.4f\n", result.turn_number, node, u[1], u[2], JeffEngine.usage_cost(r.id))
            end
        catch e
            # snip:prod, a failed game stops loudly; the others go on and the report names it
            r.error = sprint(showerror, e)
            write(joinpath(r.dir, "ERROR.txt"), r.error)
            @error "Game $(r.id) stopped" error=r.error
        end
    end
end

function save!(r::Run)
    save_game_state(r.game, joinpath(r.dir, "game_state.yml"))
    write(joinpath(r.dir, "history.json"), JSON3.write(Dict(
        "turn_history" => r.game.turn_history, "metrics_history" => r.game.metrics_history)))
end

function main(out::String, budget::Float64, max_rounds::Int)
    isempty(JeffEngine.read_key("ANTHROPIC_API_KEY")) && error("No API key: set JEFF_ANTHROPIC_API_KEY")
    runs = [setup(out, id, cfg) for (id, cfg) in GAMES]
    spent() = sum(JeffEngine.usage_cost(r.id) for r in runs)
    for round in 1:max_rounds
        live = filter(r -> isempty(r.error), runs)
        isempty(live) && break
        before = spent()
        @sync for r in live
            @async play_turn!(r)
        end
        foreach(save!, runs)
        cost = spent() - before
        @info @sprintf("round %d: \$%.3f this round, \$%.3f total, %d/%d games live",
                       round, cost, spent(), count(r -> isempty(r.error), runs), length(runs))
        spent() + 1.5 * cost > budget && (@info "Budget stop before round $(round + 1)"; break)
    end
    write(joinpath(out, "summary.json"), JSON3.write(Dict(
        "model" => MODEL, "budget_usd" => budget, "spent_usd" => spent(), "finished" => string(now()),
        "games" => [Dict("id" => r.id, "turns" => r.game.turn_number, "cost_usd" => JeffEngine.usage_cost(r.id),
                         "error" => r.error) for r in runs])))
    @info @sprintf("Done: \$%.3f spent", spent())
end

main(ARGS[1], parse(Float64, ARGS[2]), length(ARGS) >= 3 ? parse(Int, ARGS[3]) : 10_000)

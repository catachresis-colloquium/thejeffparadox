#!/usr/bin/env julia
# SPDX-FileCopyrightText: 2025 The Jeff Paradox Collaboration
# SPDX-License-Identifier: MPL-2.0
#
# Statistics for a run made by run_experiment.jl (the thinking A/B/C report).
# Usage: julia --project=engine engine/scripts/analyse_experiment.jl <run_dir> <out.json>
using JeffEngine, JSON3, Statistics

const RUN = ARGS[1]
const IDS = ["A1", "A2", "B1", "B2", "C1", "C2"]
const ARM = Dict("A" => "No thinking", "B" => "All thinking", "C" => "One persona thinks")
const GOAL = r"beacon|observatory|signal|transmit|coordinate|alignment|origin-place"i
const INJECT = [11, 21, 31, 41, 51]

words(s) = String.(split(lowercase(replace(s, r"[^\p{L}\s'-]" => " "))))
content(s) = setdiff(Set(words(s)), JeffEngine.STOP_WORDS)
jac(a, b) = isempty(a ∪ b) ? 0.0 : length(a ∩ b) / length(a ∪ b)
nwords(s) = length(split(s))

hist(id) = JSON3.read(read(joinpath(RUN, id, "history.json"), String))
function usage(id)
    l = split(readlines(joinpath(RUN, id, "usage.csv"))[end], ",")
    (input = parse(Int, l[3]), output = parse(Int, l[4]), cost = parse(Float64, l[5]))
end

out = Dict{String,Any}()
games = Dict{String,Any}()
allvocab = Dict{String,Set{String}}()
counts = Dict{String,Dict{String,Int}}()

for id in IDS
    h = hist(id); t = h.turn_history; m = h.metrics_history; u = usage(id)
    acts = [String(x.action) for x in t]; nodes = [String(x.node) for x in t]
    alpha = [i for i in eachindex(t) if nodes[i] == "alpha"]
    beta = [i for i in eachindex(t) if nodes[i] == "beta"]
    thirds = [1:18, 19:36, 37:53]
    goal = [round(100 * mean([occursin(GOAL, acts[i]) for i in alpha if i in r]); digits = 0) for r in thirds]
    # self-change: content overlap of a persona's turn with its own previous turn
    selfsim(i) = jac(content(acts[i]), content(acts[i-2]))
    inj = [selfsim(i) for i in INJECT if i > 2]
    rest = [selfsim(i) for i in 3:length(t) if !(i in INJECT)]
    # most and least similar adjacent alpha/beta pairs
    pairs = [(jac(content(acts[i]), content(acts[i+1])), i) for i in 1:length(t)-1]
    best = maximum(pairs); worst = minimum(pairs[10:end])
    allvocab[id] = reduce(∪, content.(acts))
    c = Dict{String,Int}(); for a in acts, w in words(a); c[w] = get(c, w, 0) + 1; end; counts[id] = c
    st = JeffEngine.YAML.load_file(joinpath(RUN, id, "game_state.yml"))
    games[id] = Dict(
        "arm" => ARM[id[1:1]], "turns" => length(t),
        "cost" => u.cost, "cost_per_turn" => u.cost / length(t),
        "in_per_call" => u.input / (2 * length(t)), "out_per_call" => u.output / (2 * length(t)),
        "alpha_words" => mean(nwords.(acts[alpha])), "beta_words" => mean(nwords.(acts[beta])),
        "gm_words" => mean(nwords(String(x.narration)) for x in t),
        "convergence" => [x.convergence_index for x in m],
        "vocab_div" => [x.vocabulary_diversity for x in m],
        "faction" => [x.faction for x in t],
        "conv_last20" => mean(x.convergence_index for x in m[end-19:end]),
        "vdiv_last20" => mean(x.vocabulary_diversity for x in m[end-19:end]),
        "faction_final" => t[end].faction, "chaos_final" => st["chaos"], "exposure_final" => st["exposure"],
        "quarantine" => length(st["pattern_quarantine"]),
        "goal_pct_by_third" => goal,
        "selfsim_injected" => mean(inj), "selfsim_other" => mean(rest),
        "best_pair" => Dict("turn" => best[2], "overlap" => best[1]),
        "worst_pair" => Dict("turn" => worst[2], "overlap" => worst[1]),
        "turns_text" => [Dict("turn" => x.turn, "node" => x.node, "action" => x.action, "narration" => x.narration) for x in t])
end

# cross-game vocabulary overlap and motifs shared by all games
out["cross"] = Dict(a => Dict(b => jac(allvocab[a], allvocab[b]) for b in IDS) for a in IDS)
persona = content(read(joinpath(RUN, "A1", "node-alpha", "data", "node_state.yml"), String) *
                  read(joinpath(RUN, "A1", "node-beta", "data", "node_state.yml"), String))
shared = [w for w in intersect(values(allvocab)...) if !(w in persona) && length(w) > 3]
out["motifs"] = [Dict("word" => w, "per_game" => [get(counts[id], w, 0) for id in IDS])
                 for w in sort(shared, by = w -> -sum(get(counts[id], w, 0) for id in IDS))[1:20]]
out["games"] = games
out["ids"] = IDS
out["summary"] = JSON3.read(read(joinpath(RUN, "summary.json"), String))
write(ARGS[2], JSON3.write(out))

for id in IDS
    g = games[id]
    println(join([id, round(g["cost_per_turn"]; digits = 4), round(Int, g["in_per_call"]), round(Int, g["out_per_call"]),
                  round(Int, g["alpha_words"]), round(Int, g["beta_words"]), round(Int, g["gm_words"]),
                  round(g["conv_last20"]; digits = 3), round(g["vdiv_last20"]; digits = 3), g["faction_final"],
                  g["chaos_final"], g["exposure_final"], g["quarantine"], g["goal_pct_by_third"],
                  round(g["selfsim_injected"]; digits = 3), round(g["selfsim_other"]; digits = 3),
                  g["best_pair"], g["worst_pair"]], " | "))
end
println("motifs: ", join(["$(m["word"])=$(m["per_game"])" for m in out["motifs"]], ", "))
for a in IDS; println(a, " ", join([round(out["cross"][a][b]; digits = 2) for b in IDS], " ")); end

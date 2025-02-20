### A Pluto.jl notebook ###
# v0.19.40

using Markdown
using InteractiveUtils

# This Pluto notebook uses @bind for interactivity. When running this notebook outside of Pluto, the following 'mock version' of @bind gives bound variables a default value (instead of an error).
macro bind(def, element)
    quote
        local iv = try Base.loaded_modules[Base.PkgId(Base.UUID("6e696c72-6542-2067-7265-42206c756150"), "AbstractPlutoDingetjes")].Bonds.initial_value catch; b -> missing; end
        local el = $(esc(element))
        global $(esc(def)) = Core.applicable(Base.get, el) ? Base.get(el) : iv(el)
        el
    end
end

# ╔═╡ 6fbdd5ca-336e-453e-a072-c022bf1b215f
begin
	using Colors
	using CSV
	using CUDA
	using cuDNN
	using DataFrames
	using DifferentiableFrankWolfe
	using Flux
	using FileIO
	using FrankWolfe
	using Graphs 
	using GridGraphs
	using Images
	using InferOpt
	using LaTeXStrings
	using LinearAlgebra
	using Markdown: MD, Admonition, Code
	using Metalhead
	using NPZ
	using Plots
	using ProgressLogging
	using Random
	using PlutoTeachingTools
	using PlutoUI
	using UnicodePlots
	using Zygote
	Random.seed!(63)
end;

# ╔═╡ 4bedc602-dfb0-11ee-2bd4-6d7b3adab5eb
md"""
**Utilities (hidden)**
"""

# ╔═╡ e566670d-80a7-46a2-868f-c1f192ae8054
md"""
Imports all package dependencies (this may take a while to run the first time)
"""

# ╔═╡ f6e42473-a82b-4218-89f6-d65c7e699741
TableOfContents(depth=3)

# ╔═╡ 44e70c56-5a44-42ca-ad49-3db02aabaafb
info(text; title="Info") = MD(Admonition("info", title, [text]));

# ╔═╡ 31e80172-283f-4dd5-9185-ffff23c99b29
logocolors = Colors.JULIA_LOGO_COLORS;

# ╔═╡ 025978d4-4f08-4ae5-9409-2157e6cb8d18
function get_angle(v)
	@assert !(norm(v) ≈ 0)
	v = v ./ norm(v)
	if v[2] >= 0
		return acos(v[1])
	else
		return π + acos(-v[1])
	end
end;

# ╔═╡ a85f0bbf-4b22-45ea-b323-cd8a349aa600
function init_plot(title)
	pl = plot(;
		aspect_ratio=:equal,
		legend=:outerleft,
		xlim=(-1.1, 1.1),
		ylim=(-1.1, 1.1),
		title=title,
	)
	return pl
end;

# ╔═╡ 7da75f97-621d-4daa-bf2c-9302c176ab38
function plot_polytope!(pl, vertices)
	plot!(
		vcat(map(first, vertices), first(vertices[1])),
		vcat(map(last, vertices), last(vertices[1]));
		fillrange=0,
		fillcolor=:gray,
		fillalpha=0.2,
		linecolor=:black,
		label=L"\mathrm{conv}(\mathcal{V})"
	)
end;

# ╔═╡ 040e9923-db8f-42c2-b797-74265d4f5b69
function plot_objective!(pl, θ)
	plot!(
		pl,
		[0., θ[1]],
		[0., θ[2]],
		color=logocolors.purple,
		arrow=true,
		lw=2,
		label=nothing
	)
	Plots.annotate!(
		pl,
		[-0.2*θ[1]],
		[-0.2*θ[2]],
		[L"\theta"],
	)
	return θ
end;

# ╔═╡ 3f405394-e637-49d1-98f8-6ecfc7c778a7
function plot_maximizer!(pl, θ, polytope, maximizer)
	ŷ = maximizer(θ; polytope)
	scatter!(
		pl,
		[ŷ[1]],
		[ŷ[2]];
		color=logocolors.red,
		markersize=9,
		markershape=:square,
		label=L"f(\theta)"
	)
end;

# ╔═╡ e9774758-f1c1-4a5c-821f-34fb78503b79
function plot_distribution!(pl, probadist)
	A = probadist.atoms
	As = sort(A, by=get_angle)
	p = probadist.weights
	plot!(
		pl,
		vcat(map(first, As), first(As[1])),
		vcat(map(last, As), last(As[1]));
		fillrange=0,
		fillcolor=:blue,
		fillalpha=0.1,
		linestyle=:dash,
		linecolor=logocolors.blue,
		label=L"\mathrm{conv}(\hat{p}(\theta))"
	)
	scatter!(
		pl,
		map(first, A),
		map(last, A);
		markersize=25 .* p .^ 0.5,
		markercolor=logocolors.blue,
		markerstrokewidth=0,
		markeralpha=0.4,
		label=L"\hat{p}(\theta)"
	)
end;

# ╔═╡ 8a94c7e1-b026-4030-9539-647e954f7d1f
function plot_expectation!(pl, probadist)
	ŷΩ = compute_expectation(probadist)
	scatter!(
		pl,
		[ŷΩ[1]],
		[ŷΩ[2]];
		color=logocolors.blue,
		markersize=6,
		markershape=:hexagon,
		label=L"\hat{f}(\theta)"
	)
end;

# ╔═╡ d1c0d37e-303a-424d-bb8b-e7c9b790b08c
function compress_distribution!(
    probadist::FixedAtomsProbabilityDistribution{A,W}; atol=0
) where {A,W}
    (; atoms, weights) = probadist
    to_delete = Int[]
    for i in length(probadist):-1:1
        ai = atoms[i]
        for j in 1:(i - 1)
            aj = atoms[j]
            if isapprox(ai, aj; atol=atol)
                weights[j] += weights[i]
                push!(to_delete, i)
                break
            end
        end
    end
    sort!(to_delete)
    deleteat!(atoms, to_delete)
    deleteat!(weights, to_delete)
    return probadist
end;

# ╔═╡ 10436cb9-1b60-48fb-85fa-f3399acf93da
set_angle_oracle = md"""
angle = $(@bind angle_oracle Slider(0:0.01:2π; default=π, show_value=false))
""";

# ╔═╡ 05d86a93-229d-45f7-aea7-b7fb365ff03e
set_angle_perturbed = md"""
angle = $(@bind angle_perturbed Slider(0:0.01:2π; default=π, show_value=false))
""";

# ╔═╡ f0ebe7af-ff03-4096-908c-f8cdc2c4bf65
set_nb_samples_perturbed = md"""
samples = $(@bind nb_samples_perturbed Slider(1:100; default=10, show_value=true))
""";

# ╔═╡ 62857553-65f7-4b6e-97b3-efca5f6f4f8b
set_epsilon_perturbed = md"""
epsilon = $(@bind epsilon_perturbed Slider(0.0:0.02:1.0; default=0.0, show_value=true))
""";

# ╔═╡ eff6c854-fb67-4dec-821c-3f8ee56563ac
set_plot_probadist_perturbed = md"""
Plot probability distribution? $(@bind plot_probadist_perturbed CheckBox())
""";

# ╔═╡ 9f67cb84-3572-48f1-890a-34c8eeae75bd
md"""
# Shortest paths on satellite images
"""

# ╔═╡ 26b1995b-606b-441d-8707-b0212fa504e9
ChooseDisplayMode()

# ╔═╡ 8f5ff133-120f-44c5-b522-adbd01072af0
md"""
- Each green question box expect a written answer. For this, replace the `still_missing()` yellow box after by `md"Your answer"`.
- TODO boxes expect some code implementation, and eventually some comments and analyis.
"""

# ╔═╡ 7e6b8425-76db-4d0f-9f3e-2edb05a3beae
tip(md"""This file is a [Pluto](https://plutojl.org/) notebook. There are some differences respect to Jupyter notebooks you may be familiar with:
- It's a regular julia code file.
- **Self-contained** environment: packages are managed and installed directly in each notebook.
- **Reactivity** and interactivity: cells are connected, such that when you modify a variable value, all other cells depending on it (i.e. using this variable) are automatically reloaded and their outputs updated. Feel free to modify some variables to observe the effects on the other cells. This allow interactivity with tools such as dropdown and sliders.
""")

# ╔═╡ f8b5b467-d1c6-4849-9a40-000fb0de92ef
md"""
# 1. Overview on ML and OR
"""

# ╔═╡ 28e64f94-a97a-4573-b224-9d193bea4343
ChooseDisplayMode()

# ╔═╡ 66dd1933-a014-4280-a510-c9f686fa94a8
md"""
## I. Machine Learning (ML)
"""

# ╔═╡ 758c6b95-f828-4f47-a753-329a8e92856f
md"""
Machine Learning (ML) is often seen as a broaf sub-field of Artificial Intelligence (AI). It consists in learning to perform a task based on data. This task is mostly descriptive or predictive. It can be split in different paradigms: 
- supervised learning
- unsupervised learning
- reinforcement learning


In mathematics, "learning to perform a task based on data" is roughly formulated as optimizing a (often convex and differentiable) loss function with respect to some model weights, given a data set of samples. The model weights are used to parameterize a function to perform the same task on new samples.
"""

# ╔═╡ faf4da2d-d5f3-47e0-9faa-88ede775dce1
question_box(md"Which technique is at the core of ML when optimizing a convex differentiable loss ?")

# ╔═╡ 4a7f4066-8c34-4afe-ba50-20fc7d98f88e
still_missing(md"Write your answer here.")

# ╔═╡ 014b1ac1-7b6d-4822-900c-9c595648c52d
md"""
## II. Operations Research (OR)
"""

# ╔═╡ 094d6dff-3e6a-49ff-96e0-e4f3c9173600
md"""
Operations Research (OR) is often seen as a broaf sub-field of Artificial Intelligence (AI). According to [Rardin and Rardin](https://industri.fatek.unpatti.ac.id/wp-content/uploads/2019/03/173-Optimization-in-Operations-Research-Ronald-L.-Rardin-Edisi-2-2015.pdf): “Operations Research is the study of how to form mathematical models of complex engineering
and management problems and how to analyze them to gain insight about possible solutions.” It is prescriptive, and deeply linked to Combinatorial Optimization (CO), that consists in finding the "best" element in a finite but huge set of solutions.
"""

# ╔═╡ 2311d696-a68f-4d0a-aab5-4fda9cf2e070
md"""
# 2. Overview on CO-ML pipelines
"""

# ╔═╡ 03e05ebd-c867-4789-a1cc-6d0ac4678ac0
ChooseDisplayMode()

# ╔═╡ 4df2223f-4a13-4b0b-97a7-12e6d463484c
md"""

**Points of view**: 
1. Enrich learning pipelines with combinatorial algorithms.
2. Enhance combinatorial algorithms with learning pipelines.

```math
\xrightarrow[x]{\text{Instance}}
\fbox{ML predictor}
\xrightarrow[\theta]{\text{Objective}}
\fbox{CO algorithm}
\xrightarrow[y]{\text{Solution}}
```

**Challenge:** Differentiating through CO algorithms.

**Two main learning settings:**
- Learning by imitation: instances with labeled solutions $(x_i, y_i)_i$.
- Learning by experience: no labeled solutions $(x_i)_i$.
"""

# ╔═╡ d0e7edbd-945e-4b0c-a7a8-9eb0067e8340
md"""
## Many possible applications in both fields

- Shortest paths on satellite images
- Stochastic Vehicle Scheduling
- Two-stage Minimum Spanning Tree
- Single-machine scheduling
- Dynamic Vehicle Routing
- ...
"""

# ╔═╡ f8a99808-da26-4537-ad0a-9b62343e9eb8
md"""
## Linear oracle
"""

# ╔═╡ aa19fa99-b102-4cc4-b51f-33ae280c5a0b
md"""Let's build a polytope with `N` vertices, and visualize perturbations and loss over it."""

# ╔═╡ 61610f65-fecb-451b-b305-31bbc85e231d
N = 7

# ╔═╡ 8475b95a-3642-4cac-8de1-305ce15489c8
polytope = [[cospi(2k / N), sinpi(2k / N)] for k in 0:N-1];

# ╔═╡ dcbfab0f-f733-4ea7-a642-aaa69daaa2ec
md"""Combinatorial oracle: ``f(\theta; x) = \arg\max_{y\in\mathcal{Y}(x)} \theta^\top y``"""

# ╔═╡ 6ffb3595-ab53-4483-bde6-f4db4becec9e
maximizer(θ; polytope) = polytope[argmax(dot(θ, v) for v in polytope)];

# ╔═╡ e9b6a04a-3c07-4892-a873-4ed4b75b8e2e
md"""
Here is a figure of the polytope and the armax output of the oracle in red.

You can modify θ by using the slider below to modify its angle:
"""

# ╔═╡ 5f74bee1-af3e-49b2-9353-a87fff5a6d90
let
	θ = 0.5 .* [cos(angle_oracle), sin(angle_oracle)]
	pl = init_plot("Linear oracle")
	plot_polytope!(pl, polytope)
	plot_objective!(pl, θ)
	plot_maximizer!(pl, θ, polytope, maximizer)
	pl
end

# ╔═╡ 51186111-e7e0-41ad-97e3-d15744cd494a
set_angle_oracle

# ╔═╡ d6ceb0fd-76e9-4ea0-8fb4-eb289e0567dc
md"""We use the [`Zygote.jl`](https://fluxml.ai/Zygote.jl/stable/) automatic differentiation library to compute the jacobian of our CO oracle with respect to ``\theta``.
"""

# ╔═╡ 42ebb7aa-b91e-4f08-a161-f99d6395a6c3
let
	θ = 0.5 .* [cos(angle_oracle), sin(angle_oracle)]
	jac = Zygote.jacobian(θ -> maximizer(θ; polytope), θ)[1]
	@info "" θ=θ jacobian=jac
end

# ╔═╡ c695b023-f6c1-43e4-baa7-35b037475e15
question_box(md"Why is the jacobian zero for all values of ``\theta``?")

# ╔═╡ 835d7096-35bd-49ee-ac06-2c96adc82159
still_missing(md"Write your answer here.")

# ╔═╡ 20ee6d16-6917-4efc-92b7-0d8235da5d9e
md"""## Perturbed (or regularized) Layer"""

# ╔═╡ be088865-2763-43f4-8dca-2cc733d681a6
md"""[`InferOpt.jl`](https://github.com/axelparmentier/InferOpt.jl) provides the `PerturbedAdditive` wrapper to regularize any given combinatorial optimization oracle $f$, and transform it into $\hat f$.

It takes the maximizer as the main arguments, and several optional keyword arguments such as:
- `ε`: size of the perturbation (=1 by default)
- `nb_samples`: number of Monte Carlo samples to draw for estimating expectations (=1 by default)

See the [documentation](https://axelparmentier.github.io/InferOpt.jl/dev/) for more details.
"""

# ╔═╡ 0ef3125f-e635-4ca7-8a26-00e07ec3a265
perturbed_layer = PerturbedAdditive(
	maximizer;
	ε=epsilon_perturbed,
	nb_samples=nb_samples_perturbed,
	seed=0
)

# ╔═╡ f4b1420e-af51-4efa-a81d-cf82884dc519
md"""Now we can visualize the perturbed maximizer output"""

# ╔═╡ 13573751-41c7-4d6a-8d40-08e6392eb6a1
TwoColumn(set_angle_perturbed, set_epsilon_perturbed)

# ╔═╡ c6d0a5e0-3fc9-45ba-a750-c7a656dc0841
TwoColumn(set_nb_samples_perturbed, set_plot_probadist_perturbed)

# ╔═╡ e616fb4c-4c2e-441e-bad8-0ff44caebca3
let
	θ = 0.5 .* [cos(angle_perturbed), sin(angle_perturbed)]
	probadist = compute_probability_distribution(
		perturbed_layer, θ; polytope,
	)
	compress_distribution!(probadist)
	pl = init_plot("Perturbation")
	plot_polytope!(pl, polytope)
	plot_objective!(pl, θ)
	plot_probadist_perturbed && plot_distribution!(pl, probadist)
	plot_maximizer!(pl, θ, polytope, maximizer)
	plot_expectation!(pl, probadist)
	pl
end

# ╔═╡ b78843f7-66a3-430c-bdd6-5e079851a723
md"""The perturbed maximizer is differentiable:"""

# ╔═╡ e910fa15-fc25-4e09-9cac-6b1ef0da96f9
let
	θ = 0.5 .* [cos(angle_perturbed), sin(angle_perturbed)]
	Zygote.jacobian(θ -> perturbed_layer(θ; polytope), θ)[1]
end

# ╔═╡ 10d02a49-9943-4016-afdb-ca11a80d8711
question_box(md"What can you say about the derivatives of the perturbed maximizer?")

# ╔═╡ 41d90aba-8f92-4aa7-81ee-7ec6b3d652b6
still_missing(md"Write your answer here.")

# ╔═╡ 7b6844bc-e2ab-4b81-b745-d467ee56410b
md"""
## Fenchel-Young loss (learning by imitation)
By defining:

```math
F^+_\varepsilon (\theta) := \mathbb{E}_{Z}\big[ \operatorname{max}_{y \in \mathcal{Y}(x)} (\theta + \varepsilon Z)^\top y \big],
```
and ``\Omega_\varepsilon^+`` its Fenchel conjugate, we can define the Fenchel-Young loss as follows:
```math
\mathcal{L}_{\varepsilon}^{\text{FY}}(\theta, \bar{y}) = F^+_\varepsilon (\theta) + \Omega_\varepsilon(\bar{y}) - \theta^\top \bar{y}
```

Given a target solution $\bar{y}$ and a parameter $\theta$, a subgradient is given by:
```math
\widehat{f}(\theta) - \bar{y} \in \partial_\theta \mathcal{L}_{\varepsilon}^{\text{FY}}(\theta, \bar{y}).
```
The optimization block has meaningful gradients $\implies$ we can backpropagate through the whole pipeline, using automatic differentiation.
"""

# ╔═╡ 78d9fb11-e056-4bc2-a656-1e2baf417053
question_box(md"What are the properties of ``\mathcal{L}_{\varepsilon}^{\text{FY}}?``")

# ╔═╡ be813c1b-5a05-4e82-8d5b-b750cd87239e
still_missing(md"Write your answer here.")

# ╔═╡ cb4dc416-8aa3-4976-b84b-67a91051a338
md"""
# 3. Pathfinding on satellite images
"""

# ╔═╡ 9e3cf607-3bf6-442f-aaf9-717f4243583d
md"""
In this section, we define learning pipelines for the satellite image shortest path problem. 
We have a sub-dataset of satellite images, corresponding black-box cost functions, and optionally the label shortest path solutions and cell costs. 
We want to learn the cost of the cells, using a neural network embedding, to predict good shortest paths on new test images.
More precisely, each point in our dataset consists in:
- an image of terrain ``I``.
- a black-box cost function ``c`` to evaluate any given path (optional).
- a label shortest path ``P`` from the top-left to the bottom-right corners (optional). 
- the true cost of each cell of the grid (optional).
We can exploit the images to approximate the true cell costs, so that when considering a new test satellite, we predict a good shortest path from its top-left to its bottom-right corners.
The question is: how should we combine these features?
We use `InferOpt` to learn the appropriate costs.

In what follows, we'll build the following pipeline:
"""

# ╔═╡ e145d20d-a00d-4921-9af9-ce60353ad2ce
md"""
## I - Dataset and plots
"""

# ╔═╡ c3c0443b-ecf0-4ffd-b61f-7da543ee14e2
md"""
We first give the path of the dataset folder:
"""

# ╔═╡ c6046b2b-2253-4929-9438-e2a074a9de10
decompressed_path = joinpath(".", "data/prepared_data/")

# ╔═╡ 6e5f6c54-4112-488d-96e4-a740a5d6c521
md"""
### a) Gridgraphs
"""

# ╔═╡ 630effa0-9f3d-4a55-abdd-b4e9549e046f
md"""For the purposes of this TP, we consider grid graphs, as implemented in [GridGraphs.jl](https://github.com/gdalle/GridGraphs.jl).
In such graphs, each vertex corresponds to a couple of coordinates ``(i, j)``, where ``1 \leq i \leq h`` and ``1 \leq j \leq w``.
"""

# ╔═╡ ac31f43d-d3b0-44da-8d10-a7f7cd497669
h, w = 12, 12;

# ╔═╡ f663b179-ed6a-459d-9c7e-3807cf80239a
g = GridGraph(rand(h, w); directions=QUEEN_DIRECTIONS)

# ╔═╡ 267c58f5-d1d2-4141-a552-acb0ada0bf1f
g.vertex_weights

# ╔═╡ d9fa8250-3634-4b76-88d8-65e929f35b7d
md"""For convenience, `GridGraphs.jl` also provides custom functions to compute shortest paths efficiently. We use the Dijkstra implementation.
Let us see what those paths look like.
"""

# ╔═╡ 5efd5d67-c422-49c3-959c-ade66b38633d
grid_dijkstra(g, 1, nv(g))

# ╔═╡ 1124fbb3-18b4-41c2-958d-3d2d4dd40cfe
grid_bellman_ford(g, 1, nv(g))

# ╔═╡ 5a63cad5-f874-4390-b78c-498ce2180c3f
p = path_to_matrix(g, grid_dijkstra(g, 1, nv(g)))

# ╔═╡ 38cd5fb5-3f07-4a4e-bea4-57cdae02d798
md"""
### b) Dataset functions
"""

# ╔═╡ 41bdc919-ddcc-40f4-bd16-3f5a26485529
md"""
The first dataset function `read_dataset` is used to read the images, cell costs and shortest path labels stored in files of the dataset folder.
"""

# ╔═╡ bec571ff-86c7-4fd7-afcd-c27595563824
"""
	read_dataset(decompressed_path::String, dtype::String="train", nb_samples::Int)

Read the dataset of type `dtype` at the `decompressed_path` location.
The dataset is made of images of satellite terrains, cell cost labels and shortest path labels.
They are returned separately, with proper axis permutation and image scaling to be consistent with 
`Flux` embeddings.
"""
function read_dataset(decompressed_path::String, dtype::String="train",nb_samples::Int=100)
	# metadata
	metadata_df = DataFrame(CSV.File(joinpath(decompressed_path, "metadata.csv")))
	names_dtype = metadata_df[metadata_df[!, "split"] .== dtype, "image_id"][1:nb_samples]
	# get the size of images and weights to create arrays
	size_image = size(channelview(FileIO.load(joinpath(decompressed_path, dtype, "$(names_dtype[1])_sat.jpg"))))
	# size_weight = size(npzread(joinpath(decompressed_path, dtype, "$(names_dtype[1])_sat.npy")))
	size_mask = size(channelview(FileIO.load(joinpath(decompressed_path, dtype, "$(names_dtype[1])_mask.png"))))
	size_path = size(npzread(joinpath(decompressed_path, dtype, "$(names_dtype[1])_shortest_path.npy")))
	# create arrays to fill
	terrain_images = Array{Float32}(undef, length(names_dtype), size_image[1], size_image[2], size_image[3])
	# terrain_weights = Array{Float32}(undef, length(names_dtype), size_weight[1], size_weight[2])
	terrain_masks = Array{Float32}(undef, length(names_dtype), size_mask[1], size_mask[2], size_mask[3])
	terrain_paths = Array{Float32}(undef, length(names_dtype), size_path[1], size_path[2])
	@progress for (i, name) in enumerate(names_dtype)
		# Open files
		terrain_images[i, :, :, :] = channelview(FileIO.load(joinpath(decompressed_path, dtype, "$(name)_sat.jpg")))
		# terrain_weights[i, :, :] = npzread(joinpath(decompressed_path, dtype, "$(name)_sat.npy"))
		terrain_masks[i, :, :, :] = channelview(FileIO.load(joinpath(decompressed_path, dtype, "$(name)_mask.png")))
		terrain_paths[i, :, :] = npzread(joinpath(decompressed_path, dtype, "$(name)_shortest_path.npy"))	
	end
	# Reshape for Flux
	process_model = Flux.Chain(AdaptiveMaxPool((32,32)),
        average_tensor,
        neg_tensor,
		x -> 1 .+ x,
		x-> reshape(x, size(x, 1), size(x, 2), size(x, 4))
	)
	terrain_images = permutedims(terrain_images, (3, 4, 2, 1))
	terrain_masks = permutedims(terrain_masks, (3, 4, 2, 1))
	# terrain_weights = permutedims(terrain_weights, (2, 3, 1))
	terrain_weights = process_model(terrain_masks)
	terrain_paths = permutedims(terrain_paths, (2, 3, 1))
	println("Train images shape: ", size(terrain_images))
	println("Train masks shape: ", size(terrain_masks))
	println("Weights shape:", size(terrain_weights))
	println("Train labels shape: ", size(terrain_paths))
	return terrain_images, terrain_masks, terrain_weights, terrain_paths
end

# ╔═╡ a36e80da-6780-44ca-9e00-a42af83e3657
md"""
Once the files are read, we want to give an adequate format to the dataset, so that we can easily load samples to train and test models. The function `create_dataset` therefore calls the previous `read_dataset` function: 
"""

# ╔═╡ 5ff9ad90-c472-4eb9-9b31-4c5dffe44145
"""
	create_dataset(decompressed_path::String, nb_samples::Int=10000)

Create the dataset corresponding to the data located at `decompressed_path`, possibly sub-sampling `nb_samples` points.
The dataset is made of images of satellite terrains, cell cost labels and shortest path labels.
It is a `Vector` of tuples, each `Tuple` being a dataset point.
"""
function create_dataset(decompressed_path::String, nb_samples::Int=10000)
	terrain_images, terrain_masks, terrain_weights, terrain_paths = read_dataset(
		decompressed_path, "train", nb_samples
	)
	X = [
		reshape(terrain_images[:, :, :, i], (size(terrain_images[:, :, :, i])..., 1)) for
		i in 1:nb_samples
	]
	Y = [terrain_paths[:, :, i] for i in 1:nb_samples]
	WG = [terrain_weights[:, :, i] for i in 1:nb_samples]
	M = [terrain_masks[:, :, :, i] for i in 1:nb_samples]
	return collect(zip(X, M, WG, Y))
end

# ╔═╡ 80defee2-8e56-4375-84dc-99bee48883da
md"""
Last, as usual in machine learning implementations, we split a dataset into train and test sets. The function `train_test_split` does the job:

"""

# ╔═╡ 687fc8b5-77a8-4875-b5e9-f942684ac6b6
"""
	train_test_split(X::AbstractVector, train_percentage::Real=0.5)

Split a dataset contained in `X` into train and test datasets.
The proportion of the initial dataset kept in the train set is `train_percentage`.
"""
function train_test_split(X::AbstractVector, train_percentage::Real=0.5)
	N = length(X)
	N_train = floor(Int, N * train_percentage)
	N_test = N - N_train
	train_ind, test_ind = 1:N_train, (N_train + 1):(N_train + N_test)
	X_train, X_test = X[train_ind], X[test_ind]
	return X_train, X_test
end

# ╔═╡ 69b6a4fe-c8f8-4371-abe1-906bc690d4a2
md"""
### c) Plot functions
"""

# ╔═╡ 8fcc69eb-9f6c-4fb1-a70c-80216eed306b
md"""
In the following cell, we define utility plot functions to have a glimpse at images, cell costs and paths. Their implementation is not at the core of this tutorial, they are thus hidden.
"""

# ╔═╡ 90c5cf85-de79-43db-8cba-39fda06938e6
begin 
	"""
	    convert_image_for_plot(image::Array{Float32,3})::Array{RGB{N0f8},2}
	Convert `image` to the proper data format to enable plots in Julia.
	"""
	function convert_image_for_plot(image::Array{Float32,3})::Array{RGB{N0f8},2}
	    new_img = Array{RGB{N0f8},2}(undef, size(image)[1], size(image)[2])
	    for i = 1:size(image)[1]
	        for j = 1:size(image)[2]
	            new_img[i,j] = RGB{N0f8}(image[i,j,1], image[i,j,2], image[i,j,3])
	        end
	    end
	    return new_img
	end

		"""
		plot_image_weights(;im, weights)
	Plot the image `im` and the weights `weights` on the same Figure.
	"""
	function plot_image_weights(x, θ; θ_title="Weights", θ_true=θ)
		im = dropdims(x; dims=4)
		img = convert_image_for_plot(im)
	    p1 = Plots.plot(
	        img;
	        aspect_ratio=:equal,
	        framestyle=:none,
	        size=(300, 300),
			title="Terrain image"
	    )
		p2 = Plots.heatmap(
			θ;
			yflip=true,
			aspect_ratio=:equal,
			framestyle=:none,
			padding=(0., 0.),
			size=(300, 300),
			legend=false,
			title=θ_title,
			clim=(minimum(θ_true), maximum(θ_true))
		)
	    plot(p1, p2, layout = (1, 2), size = (900, 300))
	end

		"""
		plot_image_weights_masks(;im, weights, mask)
	Plot the image `im`, the weights `weights` and the mask `mask` on the same Figure.
	"""
	function plot_image_weights_masks(x, θ, mask; θ_title="Weights", θ_true=θ)
		im = dropdims(x; dims=4)
		img = convert_image_for_plot(im)
		mask_img = convert_image_for_plot(mask)
	    p1 = Plots.plot(
	        img;
	        aspect_ratio=:equal,
	        framestyle=:none,
	        size=(300, 300),
			title="Terrain image"
	    )
		p2 = Plots.plot(
			mask_img;
			aspect_ratio=:equal,
			framestyle=:none,
			size=(300, 300),
			title="Route mask"
		)
		p3 = Plots.heatmap(
			θ;
			yflip=true,
			aspect_ratio=:equal,
			framestyle=:none,
			padding=(0., 0.),
			size=(300, 300),
			legend=false,
			title=θ_title,
			clim=(minimum(θ_true), maximum(θ_true))
		)
	    plot(p1, p2, p3, layout = (1, 3), size = (900, 300))
	end
	
	"""
		plot_image_weights_path(;im, weights, path)
	Plot the image `im`, the weights `weights`, and the path `path` on the same Figure.
	"""
	function plot_image_weights_path(x, y, θ; θ_title="Weights", y_title="Path", θ_true=θ)
		im = dropdims(x; dims=4)
		img = convert_image_for_plot(im)
	    p1 = Plots.plot(
	        img;
	        aspect_ratio=:equal,
	        framestyle=:none,
	        size=(300, 300),
			title="Terrain image"
	    )
		p2 = Plots.heatmap(
			θ;
			yflip=true,
			aspect_ratio=:equal,
			framestyle=:none,
			padding=(0., 0.),
			size=(300, 300),
			legend=false,
			title=θ_title,
			clim=(minimum(θ), maximum(θ))
		)
		p3 = Plots.plot(
	        Gray.(y .* 0.7);
	        aspect_ratio=:equal,
	        framestyle=:none,
	        size=(300, 300),
			title=y_title
	    )
	    plot(p1, p2, p3, layout = (1, 3), size = (900, 300))
	end

	"""
		plot_image_masks_weights_path(;im, mask, weights, path)
	Plot the image `im`, the weights `weights`, the mask `mask` and the path `path` on the same Figure.
	"""
	function plot_image_masks_weights_path(x, mask, θ, y; θ_title="Weights", θ_true=θ)
		im = dropdims(x; dims=4)
		img = convert_image_for_plot(im)
		mask_img = convert_image_for_plot(mask)
	    p1 = Plots.plot(
	        img;
	        aspect_ratio=:equal,
	        framestyle=:none,
	        size=(300, 300),
			title="Terrain image"
	    )
		p2 = Plots.plot(
			mask_img;
			aspect_ratio=:equal,
			framestyle=:none,
			size=(300, 300),
			title="Route mask"
		)
		p3 = Plots.heatmap(
			θ;
			yflip=true,
			aspect_ratio=:equal,
			framestyle=:none,
			padding=(0., 0.),
			size=(300, 300),
			legend=false,
			title=θ_title,
			clim=(minimum(θ_true), maximum(θ_true))
		)
		p4 = Plots.plot(
			Gray.(y .* 0.7);
			aspect_ratio=:equal,
			framestyle=:none,
			size=(300, 300),
			title="Shortest path"
		)
	    plot(p1, p2, p3, p4, layout = (2, 2), size = (900, 600))
	end
	
	"""
	    plot_loss_and_gap(losses::Matrix{Float64}, gaps::Matrix{Float64},  options::NamedTuple; filepath=nothing)
	
	Plot the train and test losses, as well as the train and test gaps computed over epochs.
	"""
	function plot_loss_and_gap(losses::Matrix{Float64}, gaps::Matrix{Float64}; filepath=nothing)
	    p1 = plot(collect(1:nb_epochs), losses, title = "Loss", xlabel = "epochs", ylabel = "loss", label = ["train" "test"])
	    p2 = plot(collect(0:nb_epochs), gaps, title = "Gap", xlabel = "epochs", ylabel = "ratio", label = ["train" "test"])
	    pl = plot(p1, p2, layout = (1, 2))
	    isnothing(filepath) || Plots.savefig(pl, filepath)
	    return pl
	end
end;

# ╔═╡ 03bc22e3-2afa-4139-b8a4-b801dd8d3f4d
md"""
### d) Import and explore the dataset
"""

# ╔═╡ 3921124d-4f08-4f3c-856b-ad876d31e2c1
md"""
Once we have both defined the functions to read and create a dataset, and to visualize it, we want to have a look at images and paths. Before that, we set the size of the dataset, as well as the train proportion: 
"""

# ╔═╡ 948eae34-738d-4c60-98b9-8b69b1eb9b68
nb_samples, train_prop = 100, 0.8;

# ╔═╡ 52292d94-5245-42b4-9c11-1c53dfc5d5fb
info(md"We focus only on $nb_samples dataset points, and use a $(trunc(Int, train_prop*100))% / $(trunc(Int, 100 - train_prop*100))% train/test split.")

# ╔═╡ 614a469e-0530-4983-82a9-e521097d57a9
begin
	dataset = create_dataset(decompressed_path, nb_samples)
	train_dataset, test_dataset = train_test_split(dataset, train_prop);
end;

# ╔═╡ 41a134b8-0c8a-4d79-931d-5df7ea524f73
md"""
We can have a glimpse at the dataset, use the slider to visualize each tuple (image, weights, label path).
"""

# ╔═╡ 42151898-a5a9-4677-aa0e-675e986bb41b
md"""
``n =`` $(@bind n Slider(1:length(dataset); default=1, show_value=true))
"""

# ╔═╡ c4b40ca8-00b0-4ea0-9793-f06adcb44f12
plot_image_masks_weights_path(dataset[n]...)

# ╔═╡ ebee2d90-d2a8-44c1-ae0b-2823c007bf1d
md"""
## II - Combinatorial functions
"""

# ╔═╡ 63a63ca9-841e-40d7-b314-d5582772b634
md"""
We focus on additional optimization functions to define the combinatorial layer of our pipelines.
"""

# ╔═╡ 0fbd9c29-c5b6-407d-931d-945d1b915cd2
md"""
### a) Recap on the shortest path problem
"""

# ╔═╡ f960b309-0250-4692-96e0-a73f79f84c71
md"""
Let $D = (V, A)$ be a digraph, $(c_a)_{a \in A}$ the cost associated to the arcs of the digraph, and $(o, d) \in V^2$ the origin and destination nodes. The problem we consider is the following:

**Shortest path problem:** Find an elementary path $P$ from node $o$ to node $d$ in the digraph $D$ with minimum cost $c(P) = \sum_{a \in P} c_a$.
"""

# ╔═╡ a88dfb2e-6aba-4ceb-b20a-829ebd3243bd
md"""
###  b) From shortest path to generic maximizer
"""

# ╔═╡ a16674b9-e4bf-4e12-a9c5-f67a61f24d7b
md"""
Now that we have defined and implemented an algorithm to deal with the shortest path problem, we wrap it in a maximizer function to match the generic framework of structured prediction.

The maximizer needs to take predicted weights `θ` as their only input, and can take some keyword arguments if needed (some instance information for example).
"""

# ╔═╡ 38f354ec-0df3-4e19-9afb-5342c89b7275
function dijkstra_maximizer(θ::AbstractMatrix; kwargs...)
	g = GridGraph(-θ; directions=QUEEN_DIRECTIONS)
	path = grid_dijkstra(g, 1, nv(g))
	y = path_to_matrix(g, path)
	return y
end

# ╔═╡ b6e0906e-6b76-44b8-a736-e7a872f8c2d7
"""
    grid_bellman_ford_satellite(g, s, d, length_max)

Apply the Bellman-Ford algorithm on an `GridGraph` `g`, and return a `ShortestPathTree` with source `s` and destination `d`,
among the paths having length smaller than `length_max`.
"""
function grid_bellman_ford_satellite(g::GridGraph{T,R,W,A}, s::Integer, d::Integer, length_max::Int = nv(g)) where {T,R,W,A}
    # Init storage
    parents = zeros(Int, nv(g), length_max + 1)
    dists = fill(Inf, nv(g), length_max + 1)
    # Add source
    dists[s, 1] = zero(T)
    # Main loop
    for k in 1:length_max
        for v in vertices(g)
            for u in inneighbors(g, v)
                d_u = dists[u, k]
                if !isinf(d_u)
                    d_v = dists[v, k + 1]
                    d_v_through_u = d_u + GridGraphs.vertex_weight(g, v)
                    if isinf(d_v) || (d_v_through_u < d_v)
                        dists[v, k + 1] = d_v_through_u
                        parents[v, k + 1] = u
                    end
                end
            end
        end
    end
    # Get length of the shortest path
    k_short = argmin(dists[d,:])
    if isinf(dists[d, k_short])
        println("No shortest path with less than $length_max arcs")
        return Int[]
    end
    # Deduce the path
    v = d
    path = [v]
    k = k_short
    while v != s
        v = parents[v, k]
        if v == 0
            return Int[]
        else
            pushfirst!(path, v)
            k = k - 1
        end
    end
    return path
end

# ╔═╡ 3e54bce5-faf9-4954-980f-5d70737a3494
function bellman_maximizer(θ::AbstractMatrix; kwargs...)
	g = GridGraph(-θ; directions=QUEEN_DIRECTIONS)
	path = grid_bellman_ford_satellite(g, 1, nv(g))
	y = path_to_matrix(g, path)
	return y
end

# ╔═╡ 22a00cb0-5aca-492b-beec-407ac7ef13d4
danger(md"`InferOpt.jl` wrappers only take maximization algorithms as input. Don't forget to change some signs if your solving a minimization problem instead.")

# ╔═╡ 596f8aee-34f4-4304-abbe-7100383ce0d1
md"""
!!! info "The maximizer function will depend on the pipeline"
	Note that we use the function `grid_dijkstra` already implemented in the `GridGraphs.jl` package when we deal with non-negative cell costs. In the following, we will use either Dijkstra or Ford-Bellman algorithm depending on the learning pipeline. You will have to modify the maximizer function to use depending on the experience you do.
"""

# ╔═╡ 8581d294-4d19-40dc-a10a-79e8922ecedb
md"""
``n_p =`` $(@bind n_p Slider(1:length(dataset); default=1, show_value=true))
"""

# ╔═╡ 62d66917-ef2e-4e64-ae6d-c281b8e81b4f
plot_image_weights_masks(dataset[n_p][1], dataset[n_p][3], dataset[n_p][2])

# ╔═╡ 67d8f55d-bdbe-4407-bf9b-b34805edcb76
ground_truth_path = bellman_maximizer(-dataset[n_p][3])

# ╔═╡ 34701d56-63d1-4f6d-b3d0-52705f4f8820
plot_image_weights_path(dataset[n_p][1], ground_truth_path, dataset[n_p][3]; θ_title="Weights", y_title="Path", θ_true=dataset[n_p][3])

# ╔═╡ 92cbd9fb-2fdf-45ed-aed5-2cc772c09a93
dataset[n_p][3]

# ╔═╡ 87cbc472-6330-4a27-b10f-b8d881b79249
md"""
The following cell is used to create and save the shortest paths based on ground truth weights:
"""

# ╔═╡ 3476d181-ba67-4597-b05c-9caec23fa1e5
# begin
# 	metadata_df = DataFrame(CSV.File(joinpath(decompressed_path, "metadata.csv")))
# 	names_dtype = metadata_df[metadata_df[!, "split"] .== "train", "image_id"][1:nb_samples]
# 	@progress for (i, (x, m, w, y)) in enumerate(dataset)
# 		ground_truth_path = bellman_maximizer(-w)
# 		npzwrite(joinpath(decompressed_path, "train", "$(names_dtype[i])_shortest_path.npy"), ground_truth_path)
# 	end
# end

# ╔═╡ b8b79a69-2bbb-4329-a1d0-3429230787c1
md"""
## III - Learning functions
"""

# ╔═╡ 37761f25-bf80-47ee-9fca-06fce1047364
md"""
### a) Convolutional neural network: predictor for the cost vector
"""

# ╔═╡ 97df1403-7858-4715-856d-f330926a9bfd
md"""
We implemenat several elementary functions to define our machine learning predictor for the cell costs.
"""

# ╔═╡ 02d14966-9887-40cb-a04d-09774ff72d27
"""
    average_tensor(x)

Average the tensor `x` along its third axis.
"""
function average_tensor(x)
    return sum(x, dims = [3])/size(x)[3]
end

# ╔═╡ a9ca100d-8881-4c31-9ab9-e987baf91e2c
"""
    neg_tensor(x)

Compute minus softplus element-wise on tensor `x`.
"""
function neg_tensor(x)
    return -relu.(x)
end

# ╔═╡ 721893e8-9252-4fcd-9ef7-59b70bffb916
"""
    squeeze_last_dims(x)

Squeeze two last dimensions on tensor `x`.
"""
function squeeze_last_dims(x)
    return reshape(x, size(x, 1), size(x, 2))
end

# ╔═╡ 8666701b-223f-4dfc-a4ff-aec17c7e0ab2
md"""
!!! info "CNN as predictor"
	The following function defines the convolutional neural network we will use as cell costs predictor.
"""

# ╔═╡ 1df5a84a-7ef3-43fc-8ffe-6a8245b31f8e
"""
    create_satellite_embedding()

Create and return a `Flux.Chain` embedding for the satellite images, inspired by [differentiation of blackbox combinatorial solvers](https://github.com/martius-lab/blackbox-differentiation-combinatorial-solvers/blob/master/models.py).

The embedding is made as follows:
1) The first 5 layers of ResNet18 (convolution, batch normalization, relu, maxpooling and first resnet block).
2) An adaptive maxpooling layer to get a (12x12x64) tensor per input image.
3) An average over the third axis (of size 64) to get a (12x12x1) tensor per input image.
4) The element-wize `neg_tensor` function to get cell weights of proper sign to apply shortest path algorithms.
5) A squeeze function to forget the two last dimensions. 
"""
function create_satellite_embedding()
    resnet18 = ResNet(18; pretrain=false, nclasses=1)
    model_embedding = Chain(
		resnet18.layers[1][1][1],
		resnet18.layers[1][1][2],
		resnet18.layers[1][1][3],
		resnet18.layers[1][2][1],
        AdaptiveMaxPool((32,32)),
        average_tensor,
        neg_tensor,
        squeeze_last_dims,
    )
    return model_embedding
end

# ╔═╡ f42d1915-3490-4ae4-bb19-ac1383f453dc
md"""
We can build the encoder this way:
"""

# ╔═╡ 87f1b50a-cb53-4aac-aed6-b3c7c36959b0
initial_encoder = create_satellite_embedding() |> gpu

# ╔═╡ 10ce5116-edfa-4b1a-9f9f-7400e5b761ec
md"""
### b) Loss and gap utility functions
"""

# ╔═╡ c69f0a97-84d6-4fd9-bf02-4cfa2132a9c1
md"""
In the cell below, we define the `cost` function seen as black-box to evaluate the cost of a given path on the grid, given the true costs `c_true`.
"""

# ╔═╡ aa35bdee-3d2c-49ff-9483-795e0024de0c
cost(y; c_true) = dot(y, c_true)

# ╔═╡ 3df21310-c44a-4132-acc0-a0db265a23a9
md"""
During training, we want to evaluate the quality of the predicted paths, both on the train and test datasets. We define the shortest path cost ratio between a candidate shortest path $\hat{y}$ and the label shortest path $y$ as: $r(\hat{y},y) = c(\hat{y}) / c(y)$.
"""

# ╔═╡ 7469895b-06d2-4832-b981-d62b14a80fa8
md"""
!!! info
	The following code defines the `shortest_path_cost_ratio` function. The candidate path $\hat{y}$ is given by the output of `model` applied on image `x`, and `y` is the target shortest path.
"""

# ╔═╡ 8ce55cdd-6c1a-4fc3-843a-aa6ed1ad4c62
"""
	shortest_path_cost_ratio(model, x, y, kwargs)
Compute the ratio between the cost of the solution given by the `model` cell costs and the cost of the true solution.
We evaluate both the shortest path with respect to the weights given by `model(x)` and the labelled shortest path `y`
using the true cell costs stored in `kwargs.wg.weights`. 
This ratio is by definition greater than one. The closer it is to one, the better is the solution given by the current 
weights of `model`. We thus track this metric during training.
"""
function shortest_path_cost_ratio(model, x, y_true, θ_true; maximizer)
	θ_cpu = model(x) |> cpu
	y = maximizer(θ_cpu)
	return dot(cpu(θ_true), y) / dot(cpu(θ_true), cpu(y_true))
end

# ╔═╡ 15ffc121-b27c-4eec-a829-a05904215426
"""
	shortest_path_cost_ratio(model, batch)
Compute the average cost ratio between computed and true shorest paths over `batch`. 
"""
function shortest_path_cost_ratio(model, batch; maximizer)
	return sum(shortest_path_cost_ratio(model, item[1], item[4], item[3]; maximizer) for item in batch) / length(batch)
end

# ╔═╡ 0adbb1a4-6e19-40d5-8f9d-865d932cd745
"""
	shortest_path_cost_gap(; model, dataset)
Compute the average cost ratio between computed and true shorest paths over `dataset`. 
"""
function shortest_path_cost_gap(; model, dataset, maximizer)
	return (sum(shortest_path_cost_ratio(model, batch; maximizer) for batch in dataset) / length(dataset) - 1) * 100
end

# ╔═╡ fd3a4158-5b98-4ddb-a8bd-3603259ee490
md"""
### c) Main training function
"""

# ╔═╡ ea70f8e7-e25b-49cc-8cc2-e25b1aef6b0a
md"""
We now consider the generic learning function. We want to minimize a given `flux_loss` over the `train_dataset`, by updating the parameters of `encoder`. We do so using `Flux.jl` package which contains utility functions to backpropagate in a stochastic gradient descent framework. We also track the loss and cost ratio metrics both on the train and test sets. The hyper-parameters are stored in the `options` tuple. 
"""

# ╔═╡ be2184a8-fed0-4a97-81cb-0b727f9c0444
md"""
The following block defines the generic learning function.
"""

# ╔═╡ c5e1ae85-8168-4cce-9b20-1cf21393a49f
md"""
## IV - Pipelines
"""

# ╔═╡ 3d28d1b4-9f99-44f6-97b5-110f675b5c22
md"""
As you know, the solution of a linear program is not differentiable with respect to its cost vector. Therefore, we need additional tricks to be able to update the parameters of the CNN defined by `create_warcraft_embedding`. Two points of view can be adopted: perturb or regularize the maximization problem. They can be unified when introducing probabilistic combinatorial layers, detailed in this [paper](https://arxiv.org/pdf/2207.13513.pdf). They are used in two different frameworks:

- Learning by imitation when we have target shortest path examples in the dataset.
- Learning by experience when we only have access to the images and to a black-box cost function to evaluate any candidate path.

In this section, we explore different combinatorial layers, as well as the learning by imitation and learning by experience settings.
"""

# ╔═╡ f532c661-79ad-4c30-8aec-0379a84a3204
md"""
### a) Learning by imitation with additive perturbation
"""

# ╔═╡ d84a9ab0-647a-4bb2-978d-4720b6588d9c
md"""
#### 1) Hyperparameters
"""

# ╔═╡ d4e50757-e67c-4206-a943-c2793d1680ab
md"""
We first define the hyper-parameters for the learning process. They include:
- The regularization size $\varepsilon$.
- The number of samples drawn for the approximation of the expectation $M$.
- The number of learning epochs `nb_epochs`.
- The batch size for the stochastic gradient descent `batch_size`.
- The starting learning rate for ADAM optimizer `lr_start`.
"""

# ╔═╡ 84800e5c-9ce2-4a37-aa3c-8f8e7e3d708c
begin
	ε = 0.1
	M = 10
	nb_epochs = 10
	batch_size = 5
	lr_start = 1e-3
end;

# ╔═╡ 6619b9ae-2608-4c8d-9561-bc579d673651
function train_function!(;
	encoder, loss, train_data, test_data, lr_start, nb_epoch, batch_size, maximizer
)
	# batch stuff
	batch_loss(batch) = sum(loss(item...) for item in batch)
	train_dataset = Flux.DataLoader(train_data; batchsize=batch_size) |> gpu
	test_dataset = Flux.DataLoader(test_data; batchsize=length(test_data)) |> gpu

	# Store the train loss and gap metric
	losses = Matrix{Float64}(undef, nb_epochs, 2)
	cost_gaps = Matrix{Float64}(undef, nb_epochs + 1, 2)

	# Optimizer
	opt = ADAM(lr_start)

	# model parameters
	par = Flux.params(encoder)

	cost_gaps[1, 1] = shortest_path_cost_gap(; model=encoder, dataset=train_dataset, maximizer)
	cost_gaps[1, 2] = shortest_path_cost_gap(; model=encoder, dataset=test_dataset, maximizer)

	# Train loop
	@progress "Training epoch: " for epoch in 1:nb_epochs
		train_loss = 0.0
		for batch in train_dataset
			loss_value = 0
			gs = gradient(par) do
				loss_value = batch_loss(batch)
			end
			train_loss += loss_value
			Flux.update!(opt, par, gs)
		end

		# compute and store epoch metrics
		losses[epoch, 1] = train_loss / (nb_samples * train_prop)
		losses[epoch, 2] = sum([batch_loss(batch) for batch in test_dataset]) / (nb_samples * (1 - train_prop))
		cost_gaps[epoch + 1, 1] = shortest_path_cost_gap(; model=encoder, dataset=train_dataset, maximizer)
		cost_gaps[epoch + 1, 2] = shortest_path_cost_gap(; model=encoder, dataset=test_dataset, maximizer)
	end
	 return losses, cost_gaps, deepcopy(encoder)
end

# ╔═╡ 83163af1-cdf7-4987-a159-17a19b70f65f
tip(md"Feel free to play around with hyperparameters, observe and report their impact on the training performances.")

# ╔═╡ 63280424-98d6-406a-b392-e124dc9fd0cb
md"""
#### 2) Specific pipeline
"""

# ╔═╡ 115805d5-3084-4011-8268-071427dc7eea
md"""
!!! info "What is a pipeline ?"
	This portion of code is the crucial part to define the learning pipeline. It contains: 
	- an encoder, the machine learning predictor, in our case a CNN.
	- a maximizer possibly applied to the output of the encoder before computing the loss.
	- a differentiable loss to evaluate the quality of the output of the pipeline.
	
	Its definition depends on the learning setting we consider.
"""

# ╔═╡ def2037e-0bd8-446d-aec2-714f4254b33a
md"As already seen in the previous sections, we wrap our shortest path algorithm in a `PerturbedAdditive`"

# ╔═╡ 984c9a6d-68b5-42d6-8b45-73153bc97980
chosen_maximizer = bellman_maximizer

# ╔═╡ b3387bae-78c6-4aa9-abdc-c49ae72f5658
perturbed_maximizer = PerturbedAdditive(chosen_maximizer; ε=ε, nb_samples=M)

# ╔═╡ 0604e53f-7eef-452c-9f8a-e96d17800254
loss = FenchelYoungLoss(perturbed_maximizer)

# ╔═╡ 6ef79e5c-ae76-48f8-8f13-c000bbfdfc04
encoder = deepcopy(initial_encoder) |> gpu

# ╔═╡ 91e63e47-f8e4-4a23-a8e3-2617879f8076
imitation_flux_loss(x, m, θ, y) = loss(cpu(encoder(x)), cpu(y))

# ╔═╡ b7e0fe81-b21d-4cff-ba63-e6db12f04c34
md"""
#### 4) Apply the learning function
"""

# ╔═╡ 4ec896f9-b226-4743-91c6-962fccc46db6
danger(md"Click the checkbox to activate the training cell $(@bind train CheckBox()) 

It may take some time to run and affect the reactivity of the notebook. Then you can read what follows.")

# ╔═╡ 7a12850f-364d-431f-b072-6038fe3c91e1
loss_history, gap_history, final_encoder = train ? train_function!(;
	encoder=encoder,
	maximizer=chosen_maximizer,
	loss=imitation_flux_loss,
	train_data=train_dataset,
	test_data=test_dataset,
	lr_start=lr_start,
	batch_size=batch_size,
	nb_epoch=nb_epochs
) : (zeros(nb_epochs, 2), zeros(nb_epochs + 1, 2), encoder);

# ╔═╡ 07b61dbd-7561-4f42-82dd-2b2c9b9b81c2
md"""
#### 5) Plot results
"""

# ╔═╡ de229acf-26c1-4dcc-a2a4-c4babc1b63e6
plot_loss_and_gap(loss_history, gap_history)

# ╔═╡ bff94ffa-73f5-4436-8655-cc8f359af8a8
md"""
!!! info "Visualize the model performance"
	We now want to see the effect of the learning process on the predicted costs and shortest paths. Use the slider to swipe through datasets.
"""

# ╔═╡ d740a3d1-6af9-4116-bd9b-3dd6a8899d0f
TwoColumn(md"Choose dataset you want to evaluate on:", md"""data = $(@bind data Select([train_dataset => "train", test_dataset => "test"]))""")

# ╔═╡ 452ba406-f073-467a-9064-b330fe9ce6cf
begin
	test_predictions = []
	dataset_to_test = data
	for (x, mask, θ_true, y_true) in dataset_to_test 
		initial_encoder_cpu = initial_encoder |> cpu
		final_encoder_cpu = final_encoder |> cpu
		θ₀ = initial_encoder_cpu(x)
		y₀ = chosen_maximizer(θ₀)
		θ = final_encoder_cpu(x)
		y = chosen_maximizer(θ)
		push!(test_predictions, (; x, y_true, θ_true, θ₀, y₀, θ, y))
	end
end

# ╔═╡ 1889d002-ec77-445c-bdb1-eb3a09a84b29
md"""
``j =`` $(@bind j Slider(1:length(dataset_to_test); default=1, show_value=true))
"""

# ╔═╡ e2d6629e-0512-43ab-adae-f916811b1fc7
(; x, y_true, θ_true, θ₀, y₀, θ, y) = test_predictions[j]

# ╔═╡ c5ce2443-745d-43ea-ac8f-4dbbe3169dd3
plot_image_weights_path(x, y_true, θ_true)

# ╔═╡ 2934b1d3-bf51-46f9-b408-6c2ff78c2625
cost(y_true; c_true = θ_true)

# ╔═╡ 29335ecb-7469-49ed-8d59-d102254f1a48
md"Predictions of the trained neural network:"

# ╔═╡ 1db9b111-f2eb-4918-acc3-c49fa2a97640
plot_image_weights_path(
	x, y, -θ; θ_title="Predicted weights", y_title="Predicted path", θ_true=θ_true
)

# ╔═╡ 2e3ffb07-454e-4a21-994a-4ecb773511a3
cost(y; c_true = θ_true)

# ╔═╡ ca0241b1-d876-4f91-9530-972f4e29b4e9
md"Predictions of the initial untrained neural network:"

# ╔═╡ 26218631-7a9e-474a-aebd-aaa3535f657d
plot_image_weights_path(
	x, y₀, -θ₀; θ_title="Initial predicted weights", y_title="Initial predicted path", θ_true=θ_true
)

# ╔═╡ c07c0c3a-f256-4481-a9e0-ef37c9877b47
cost(y₀; c_true = θ_true)

# ╔═╡ 00000000-0000-0000-0000-000000000001
PLUTO_PROJECT_TOML_CONTENTS = """
[deps]
CSV = "336ed68f-0bac-5ca0-87d4-7b16caf5d00b"
CUDA = "052768ef-5323-5732-b1bb-66c8b64840ba"
Colors = "5ae59095-9a9b-59fe-a467-6f913c188581"
DataFrames = "a93c6f00-e57d-5684-b7b6-d8193f3e46c0"
DifferentiableFrankWolfe = "b383313e-5450-4164-a800-befbd27b574d"
FileIO = "5789e2e9-d7fb-5bc7-8068-2c6fae9b9549"
Flux = "587475ba-b771-5e3f-ad9e-33799f191a9c"
FrankWolfe = "f55ce6ea-fdc5-4628-88c5-0087fe54bd30"
Graphs = "86223c79-3864-5bf0-83f7-82e725a168b6"
GridGraphs = "dd2b58c7-5af7-4f17-9e46-57c68ac813fb"
Images = "916415d5-f1e6-5110-898d-aaa5f9f070e0"
InferOpt = "4846b161-c94e-4150-8dac-c7ae193c601f"
LaTeXStrings = "b964fa9f-0449-5b57-a5c2-d3ea65f4040f"
LinearAlgebra = "37e2e46d-f89d-539d-b4ee-838fcccc9c8e"
Markdown = "d6f4376e-aef5-505a-96c1-9c027394607a"
Metalhead = "dbeba491-748d-5e0e-a39e-b530a07fa0cc"
NPZ = "15e1cf62-19b3-5cfa-8e77-841668bca605"
Plots = "91a5bcdd-55d7-5caf-9e0b-520d859cae80"
PlutoTeachingTools = "661c6b06-c737-4d37-b85c-46df65de6f69"
PlutoUI = "7f904dfe-b85e-4ff6-b463-dae2292396a8"
ProgressLogging = "33c8b6b6-d38a-422a-b730-caa89a2f386c"
Random = "9a3f8284-a2c9-5f02-9a11-845980a1fd5c"
UnicodePlots = "b8865327-cd53-5732-bb35-84acbb429228"
Zygote = "e88e6eb3-aa80-5325-afca-941959d7151f"
cuDNN = "02a925ec-e4fe-4b08-9a7e-0d78e3d38ccd"

[compat]
CSV = "~0.10.13"
CUDA = "~5.2.0"
Colors = "~0.12.10"
DataFrames = "~1.6.1"
DifferentiableFrankWolfe = "~0.2.1"
FileIO = "~1.16.2"
Flux = "~0.14.13"
FrankWolfe = "~0.3.3"
Graphs = "~1.9.0"
GridGraphs = "~0.10.0"
Images = "~0.26.0"
InferOpt = "~0.6.1"
LaTeXStrings = "~1.3.1"
Metalhead = "~0.9.3"
NPZ = "~0.4.3"
Plots = "~1.40.2"
PlutoTeachingTools = "~0.2.14"
PlutoUI = "~0.7.58"
ProgressLogging = "~0.1.4"
UnicodePlots = "~3.6.4"
Zygote = "~0.6.69"
cuDNN = "~1.3.0"
"""

# ╔═╡ 00000000-0000-0000-0000-000000000002
PLUTO_MANIFEST_TOML_CONTENTS = """
# This file is machine-generated - editing it directly is not advised

julia_version = "1.10.2"
manifest_format = "2.0"
project_hash = "08e26707c7ba253a41472736c7d8f1f44acf3551"

[[deps.AMD]]
deps = ["LinearAlgebra", "SparseArrays", "SuiteSparse_jll"]
git-tree-sha1 = "45a1272e3f809d36431e57ab22703c6896b8908f"
uuid = "14f7f29c-3bd6-536c-9a0b-7339e30b5a3e"
version = "0.5.3"

[[deps.AbstractDifferentiation]]
deps = ["ExprTools", "LinearAlgebra", "Requires"]
git-tree-sha1 = "d29ce82ed1d4c37135095e1a4d799c93d7be2361"
uuid = "c29ec348-61ec-40c8-8164-b8c60e9d9f3d"
version = "0.6.2"

    [deps.AbstractDifferentiation.extensions]
    AbstractDifferentiationChainRulesCoreExt = "ChainRulesCore"
    AbstractDifferentiationFiniteDifferencesExt = "FiniteDifferences"
    AbstractDifferentiationForwardDiffExt = ["DiffResults", "ForwardDiff"]
    AbstractDifferentiationReverseDiffExt = ["DiffResults", "ReverseDiff"]
    AbstractDifferentiationTrackerExt = "Tracker"
    AbstractDifferentiationZygoteExt = "Zygote"

    [deps.AbstractDifferentiation.weakdeps]
    ChainRulesCore = "d360d2e6-b24c-11e9-a2a3-2a2ae2dbcce4"
    DiffResults = "163ba53b-c6d8-5494-b064-1a9d43ac40c5"
    FiniteDifferences = "26cc04aa-876d-5657-8c51-4c34ba976000"
    ForwardDiff = "f6369f11-7733-5829-9624-2563aa707210"
    ReverseDiff = "37e2e3b7-166d-5795-8a7a-e32c996b4267"
    Tracker = "9f7883ad-71c0-57eb-9f7f-b5c9e6d3789c"
    Zygote = "e88e6eb3-aa80-5325-afca-941959d7151f"

[[deps.AbstractFFTs]]
deps = ["LinearAlgebra"]
git-tree-sha1 = "d92ad398961a3ed262d8bf04a1a2b8340f915fef"
uuid = "621f4979-c628-5d54-868e-fcf4e3e8185c"
version = "1.5.0"
weakdeps = ["ChainRulesCore", "Test"]

    [deps.AbstractFFTs.extensions]
    AbstractFFTsChainRulesCoreExt = "ChainRulesCore"
    AbstractFFTsTestExt = "Test"

[[deps.AbstractPlutoDingetjes]]
deps = ["Pkg"]
git-tree-sha1 = "0f748c81756f2e5e6854298f11ad8b2dfae6911a"
uuid = "6e696c72-6542-2067-7265-42206c756150"
version = "1.3.0"

[[deps.Accessors]]
deps = ["CompositionsBase", "ConstructionBase", "Dates", "InverseFunctions", "LinearAlgebra", "MacroTools", "Markdown", "Test"]
git-tree-sha1 = "c0d491ef0b135fd7d63cbc6404286bc633329425"
uuid = "7d9f7c33-5ae7-4f3b-8dc6-eff91059b697"
version = "0.1.36"

    [deps.Accessors.extensions]
    AccessorsAxisKeysExt = "AxisKeys"
    AccessorsIntervalSetsExt = "IntervalSets"
    AccessorsStaticArraysExt = "StaticArrays"
    AccessorsStructArraysExt = "StructArrays"
    AccessorsUnitfulExt = "Unitful"

    [deps.Accessors.weakdeps]
    AxisKeys = "94b1ba4f-4ee9-5380-92f1-94cde586c3c5"
    IntervalSets = "8197267c-284f-5f27-9208-e0e47529a953"
    Requires = "ae029012-a4dd-5104-9daa-d747884805df"
    StaticArrays = "90137ffa-7385-5640-81b9-e52037218182"
    StructArrays = "09ab397b-f2b6-538f-b94a-2f83cf4a842a"
    Unitful = "1986cc42-f94f-5a68-af5c-568840ba703d"

[[deps.Adapt]]
deps = ["LinearAlgebra", "Requires"]
git-tree-sha1 = "cea4ac3f5b4bc4b3000aa55afb6e5626518948fa"
uuid = "79e6a3ab-5dfb-504d-930d-738a2a938a0e"
version = "4.0.3"
weakdeps = ["StaticArrays"]

    [deps.Adapt.extensions]
    AdaptStaticArraysExt = "StaticArrays"

[[deps.ArgCheck]]
git-tree-sha1 = "a3a402a35a2f7e0b87828ccabbd5ebfbebe356b4"
uuid = "dce04be8-c92d-5529-be00-80e4d2c0e197"
version = "2.3.0"

[[deps.ArgTools]]
uuid = "0dad84c5-d112-42e6-8d28-ef12dabb789f"
version = "1.1.1"

[[deps.ArnoldiMethod]]
deps = ["LinearAlgebra", "Random", "StaticArrays"]
git-tree-sha1 = "62e51b39331de8911e4a7ff6f5aaf38a5f4cc0ae"
uuid = "ec485272-7323-5ecc-a04f-4719b315124d"
version = "0.2.0"

[[deps.Arpack]]
deps = ["Arpack_jll", "Libdl", "LinearAlgebra", "Logging"]
git-tree-sha1 = "9b9b347613394885fd1c8c7729bfc60528faa436"
uuid = "7d9fca2a-8960-54d3-9f78-7d1dccf2cb97"
version = "0.5.4"

[[deps.Arpack_jll]]
deps = ["Artifacts", "CompilerSupportLibraries_jll", "JLLWrappers", "Libdl", "OpenBLAS_jll", "Pkg"]
git-tree-sha1 = "5ba6c757e8feccf03a1554dfaf3e26b3cfc7fd5e"
uuid = "68821587-b530-5797-8361-c406ea357684"
version = "3.5.1+1"

[[deps.ArrayInterface]]
deps = ["Adapt", "LinearAlgebra", "SparseArrays", "SuiteSparse"]
git-tree-sha1 = "44691067188f6bd1b2289552a23e4b7572f4528d"
uuid = "4fba245c-0d91-5ea0-9b3e-6abc04ee57a9"
version = "7.9.0"

    [deps.ArrayInterface.extensions]
    ArrayInterfaceBandedMatricesExt = "BandedMatrices"
    ArrayInterfaceBlockBandedMatricesExt = "BlockBandedMatrices"
    ArrayInterfaceCUDAExt = "CUDA"
    ArrayInterfaceChainRulesExt = "ChainRules"
    ArrayInterfaceGPUArraysCoreExt = "GPUArraysCore"
    ArrayInterfaceReverseDiffExt = "ReverseDiff"
    ArrayInterfaceStaticArraysCoreExt = "StaticArraysCore"
    ArrayInterfaceTrackerExt = "Tracker"

    [deps.ArrayInterface.weakdeps]
    BandedMatrices = "aae01518-5342-5314-be14-df237901396f"
    BlockBandedMatrices = "ffab5731-97b5-5995-9138-79e8c1846df0"
    CUDA = "052768ef-5323-5732-b1bb-66c8b64840ba"
    ChainRules = "082447d4-558c-5d27-93f4-14fc19e9eca2"
    GPUArraysCore = "46192b85-c4d5-4398-a991-12ede77f4527"
    ReverseDiff = "37e2e3b7-166d-5795-8a7a-e32c996b4267"
    StaticArraysCore = "1e83bf80-4336-4d27-bf5d-d5a4f845583c"
    Tracker = "9f7883ad-71c0-57eb-9f7f-b5c9e6d3789c"

[[deps.Artifacts]]
uuid = "56f22d72-fd6d-98f1-02f0-08ddc0907c33"

[[deps.Atomix]]
deps = ["UnsafeAtomics"]
git-tree-sha1 = "c06a868224ecba914baa6942988e2f2aade419be"
uuid = "a9b6321e-bd34-4604-b9c9-b65b8de01458"
version = "0.1.0"

[[deps.AxisAlgorithms]]
deps = ["LinearAlgebra", "Random", "SparseArrays", "WoodburyMatrices"]
git-tree-sha1 = "01b8ccb13d68535d73d2b0c23e39bd23155fb712"
uuid = "13072b0f-2c55-5437-9ae7-d433b7a33950"
version = "1.1.0"

[[deps.AxisArrays]]
deps = ["Dates", "IntervalSets", "IterTools", "RangeArrays"]
git-tree-sha1 = "16351be62963a67ac4083f748fdb3cca58bfd52f"
uuid = "39de3d68-74b9-583c-8d2d-e117c070f3a9"
version = "0.4.7"

[[deps.BFloat16s]]
deps = ["LinearAlgebra", "Printf", "Random", "Test"]
git-tree-sha1 = "dbf84058d0a8cbbadee18d25cf606934b22d7c66"
uuid = "ab4f0b2a-ad5b-11e8-123f-65d77653426b"
version = "0.4.2"

[[deps.BSON]]
git-tree-sha1 = "4c3e506685c527ac6a54ccc0c8c76fd6f91b42fb"
uuid = "fbb218c0-5317-5bc6-957e-2ee96dd4b1f0"
version = "0.3.9"

[[deps.BangBang]]
deps = ["Compat", "ConstructionBase", "InitialValues", "LinearAlgebra", "Requires", "Setfield", "Tables"]
git-tree-sha1 = "7aa7ad1682f3d5754e3491bb59b8103cae28e3a3"
uuid = "198e06fe-97b7-11e9-32a5-e1d131e6ad66"
version = "0.3.40"

    [deps.BangBang.extensions]
    BangBangChainRulesCoreExt = "ChainRulesCore"
    BangBangDataFramesExt = "DataFrames"
    BangBangStaticArraysExt = "StaticArrays"
    BangBangStructArraysExt = "StructArrays"
    BangBangTypedTablesExt = "TypedTables"

    [deps.BangBang.weakdeps]
    ChainRulesCore = "d360d2e6-b24c-11e9-a2a3-2a2ae2dbcce4"
    DataFrames = "a93c6f00-e57d-5684-b7b6-d8193f3e46c0"
    StaticArrays = "90137ffa-7385-5640-81b9-e52037218182"
    StructArrays = "09ab397b-f2b6-538f-b94a-2f83cf4a842a"
    TypedTables = "9d95f2ec-7b3d-5a63-8d20-e2491e220bb9"

[[deps.Base64]]
uuid = "2a0f44e3-6c83-55bd-87e4-b1978d98bd5f"

[[deps.Baselet]]
git-tree-sha1 = "aebf55e6d7795e02ca500a689d326ac979aaf89e"
uuid = "9718e550-a3fa-408a-8086-8db961cd8217"
version = "0.1.1"

[[deps.BenchmarkTools]]
deps = ["JSON", "Logging", "Printf", "Profile", "Statistics", "UUIDs"]
git-tree-sha1 = "f1dff6729bc61f4d49e140da1af55dcd1ac97b2f"
uuid = "6e4b80f9-dd63-53aa-95a3-0cdb28fa8baf"
version = "1.5.0"

[[deps.BitFlags]]
git-tree-sha1 = "2dc09997850d68179b69dafb58ae806167a32b1b"
uuid = "d1d4a3ce-64b1-5f1a-9ba4-7e7e69966f35"
version = "0.1.8"

[[deps.BitTwiddlingConvenienceFunctions]]
deps = ["Static"]
git-tree-sha1 = "0c5f81f47bbbcf4aea7b2959135713459170798b"
uuid = "62783981-4cbd-42fc-bca8-16325de8dc4b"
version = "0.1.5"

[[deps.Bzip2_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "9e2a6b69137e6969bab0152632dcb3bc108c8bdd"
uuid = "6e34b625-4abd-537c-b88f-471c36dfa7a0"
version = "1.0.8+1"

[[deps.CEnum]]
git-tree-sha1 = "389ad5c84de1ae7cf0e28e381131c98ea87d54fc"
uuid = "fa961155-64e5-5f13-b03f-caf6b980ea82"
version = "0.5.0"

[[deps.CPUSummary]]
deps = ["CpuId", "IfElse", "PrecompileTools", "Static"]
git-tree-sha1 = "601f7e7b3d36f18790e2caf83a882d88e9b71ff1"
uuid = "2a0fbf3d-bb9c-48f3-b0a9-814d99fd7ab9"
version = "0.2.4"

[[deps.CSV]]
deps = ["CodecZlib", "Dates", "FilePathsBase", "InlineStrings", "Mmap", "Parsers", "PooledArrays", "PrecompileTools", "SentinelArrays", "Tables", "Unicode", "WeakRefStrings", "WorkerUtilities"]
git-tree-sha1 = "a44910ceb69b0d44fe262dd451ab11ead3ed0be8"
uuid = "336ed68f-0bac-5ca0-87d4-7b16caf5d00b"
version = "0.10.13"

[[deps.CUDA]]
deps = ["AbstractFFTs", "Adapt", "BFloat16s", "CEnum", "CUDA_Driver_jll", "CUDA_Runtime_Discovery", "CUDA_Runtime_jll", "Crayons", "DataFrames", "ExprTools", "GPUArrays", "GPUCompiler", "KernelAbstractions", "LLVM", "LLVMLoopInfo", "LazyArtifacts", "Libdl", "LinearAlgebra", "Logging", "NVTX", "Preferences", "PrettyTables", "Printf", "Random", "Random123", "RandomNumbers", "Reexport", "Requires", "SparseArrays", "StaticArrays", "Statistics"]
git-tree-sha1 = "baa8ea7a1ea63316fa3feb454635215773c9c845"
uuid = "052768ef-5323-5732-b1bb-66c8b64840ba"
version = "5.2.0"
weakdeps = ["ChainRulesCore", "SpecialFunctions"]

    [deps.CUDA.extensions]
    ChainRulesCoreExt = "ChainRulesCore"
    SpecialFunctionsExt = "SpecialFunctions"

[[deps.CUDA_Driver_jll]]
deps = ["Artifacts", "JLLWrappers", "LazyArtifacts", "Libdl", "Pkg"]
git-tree-sha1 = "d01bfc999768f0a31ed36f5d22a76161fc63079c"
uuid = "4ee394cb-3365-5eb0-8335-949819d2adfc"
version = "0.7.0+1"

[[deps.CUDA_Runtime_Discovery]]
deps = ["Libdl"]
git-tree-sha1 = "2cb12f6b2209f40a4b8967697689a47c50485490"
uuid = "1af6417a-86b4-443c-805f-a4643ffb695f"
version = "0.2.3"

[[deps.CUDA_Runtime_jll]]
deps = ["Artifacts", "CUDA_Driver_jll", "JLLWrappers", "LazyArtifacts", "Libdl", "TOML"]
git-tree-sha1 = "8e25c009d2bf16c2c31a70a6e9e8939f7325cc84"
uuid = "76a88914-d11a-5bdc-97e0-2f5a05c973a2"
version = "0.11.1+0"

[[deps.CUDNN_jll]]
deps = ["Artifacts", "CUDA_Runtime_jll", "JLLWrappers", "LazyArtifacts", "Libdl", "TOML"]
git-tree-sha1 = "75923dce4275ead3799b238e10178a68c07dbd3b"
uuid = "62b44479-cb7b-5706-934f-f13b2eb2e645"
version = "8.9.4+0"

[[deps.Cairo_jll]]
deps = ["Artifacts", "Bzip2_jll", "CompilerSupportLibraries_jll", "Fontconfig_jll", "FreeType2_jll", "Glib_jll", "JLLWrappers", "LZO_jll", "Libdl", "Pixman_jll", "Xorg_libXext_jll", "Xorg_libXrender_jll", "Zlib_jll", "libpng_jll"]
git-tree-sha1 = "a4c43f59baa34011e303e76f5c8c91bf58415aaf"
uuid = "83423d85-b0ee-5818-9007-b63ccbeb887a"
version = "1.18.0+1"

[[deps.Calculus]]
deps = ["LinearAlgebra"]
git-tree-sha1 = "f641eb0a4f00c343bbc32346e1217b86f3ce9dad"
uuid = "49dc2e85-a5d0-5ad3-a950-438e2897f1b9"
version = "0.5.1"

[[deps.CatIndices]]
deps = ["CustomUnitRanges", "OffsetArrays"]
git-tree-sha1 = "a0f80a09780eed9b1d106a1bf62041c2efc995bc"
uuid = "aafaddc9-749c-510e-ac4f-586e18779b91"
version = "0.2.2"

[[deps.ChainRules]]
deps = ["Adapt", "ChainRulesCore", "Compat", "Distributed", "GPUArraysCore", "IrrationalConstants", "LinearAlgebra", "Random", "RealDot", "SparseArrays", "SparseInverseSubset", "Statistics", "StructArrays", "SuiteSparse"]
git-tree-sha1 = "4e42872be98fa3343c4f8458cbda8c5c6a6fa97c"
uuid = "082447d4-558c-5d27-93f4-14fc19e9eca2"
version = "1.63.0"

[[deps.ChainRulesCore]]
deps = ["Compat", "LinearAlgebra"]
git-tree-sha1 = "575cd02e080939a33b6df6c5853d14924c08e35b"
uuid = "d360d2e6-b24c-11e9-a2a3-2a2ae2dbcce4"
version = "1.23.0"
weakdeps = ["SparseArrays"]

    [deps.ChainRulesCore.extensions]
    ChainRulesCoreSparseArraysExt = "SparseArrays"

[[deps.CloseOpenIntervals]]
deps = ["Static", "StaticArrayInterface"]
git-tree-sha1 = "70232f82ffaab9dc52585e0dd043b5e0c6b714f1"
uuid = "fb6a15b2-703c-40df-9091-08a04967cfa9"
version = "0.1.12"

[[deps.Clustering]]
deps = ["Distances", "LinearAlgebra", "NearestNeighbors", "Printf", "Random", "SparseArrays", "Statistics", "StatsBase"]
git-tree-sha1 = "9ebb045901e9bbf58767a9f34ff89831ed711aae"
uuid = "aaaa29a8-35af-508c-8bc3-b662a17a0fe5"
version = "0.15.7"

[[deps.CodeTracking]]
deps = ["InteractiveUtils", "UUIDs"]
git-tree-sha1 = "c0216e792f518b39b22212127d4a84dc31e4e386"
uuid = "da1fd8a2-8d9e-5ec2-8556-3022fb5608a2"
version = "1.3.5"

[[deps.CodecBzip2]]
deps = ["Bzip2_jll", "Libdl", "TranscodingStreams"]
git-tree-sha1 = "9b1ca1aa6ce3f71b3d1840c538a8210a043625eb"
uuid = "523fee87-0ab8-5b00-afb7-3ecf72e48cfd"
version = "0.8.2"

[[deps.CodecZlib]]
deps = ["TranscodingStreams", "Zlib_jll"]
git-tree-sha1 = "59939d8a997469ee05c4b4944560a820f9ba0d73"
uuid = "944b1d66-785c-5afd-91f1-9de20f533193"
version = "0.7.4"

[[deps.ColorSchemes]]
deps = ["ColorTypes", "ColorVectorSpace", "Colors", "FixedPointNumbers", "PrecompileTools", "Random"]
git-tree-sha1 = "67c1f244b991cad9b0aa4b7540fb758c2488b129"
uuid = "35d6a980-a343-548e-a6ea-1d62b119f2f4"
version = "3.24.0"

[[deps.ColorTypes]]
deps = ["FixedPointNumbers", "Random"]
git-tree-sha1 = "eb7f0f8307f71fac7c606984ea5fb2817275d6e4"
uuid = "3da002f7-5984-5a60-b8a6-cbb66c0b333f"
version = "0.11.4"

[[deps.ColorVectorSpace]]
deps = ["ColorTypes", "FixedPointNumbers", "LinearAlgebra", "SpecialFunctions", "Statistics", "TensorCore"]
git-tree-sha1 = "600cc5508d66b78aae350f7accdb58763ac18589"
uuid = "c3611d14-8923-5661-9e6a-0046d554d3a4"
version = "0.9.10"

[[deps.Colors]]
deps = ["ColorTypes", "FixedPointNumbers", "Reexport"]
git-tree-sha1 = "fc08e5930ee9a4e03f84bfb5211cb54e7769758a"
uuid = "5ae59095-9a9b-59fe-a467-6f913c188581"
version = "0.12.10"

[[deps.CommonSubexpressions]]
deps = ["MacroTools", "Test"]
git-tree-sha1 = "7b8a93dba8af7e3b42fecabf646260105ac373f7"
uuid = "bbf7d656-a473-5ed7-a52c-81e309532950"
version = "0.3.0"

[[deps.Compat]]
deps = ["TOML", "UUIDs"]
git-tree-sha1 = "c955881e3c981181362ae4088b35995446298b80"
uuid = "34da2185-b29b-5c13-b0c7-acf172513d20"
version = "4.14.0"
weakdeps = ["Dates", "LinearAlgebra"]

    [deps.Compat.extensions]
    CompatLinearAlgebraExt = "LinearAlgebra"

[[deps.CompilerSupportLibraries_jll]]
deps = ["Artifacts", "Libdl"]
uuid = "e66e0078-7015-5450-92f7-15fbd957f2ae"
version = "1.1.0+0"

[[deps.CompositionsBase]]
git-tree-sha1 = "802bb88cd69dfd1509f6670416bd4434015693ad"
uuid = "a33af91c-f02d-484b-be07-31d278c5ca2b"
version = "0.1.2"
weakdeps = ["InverseFunctions"]

    [deps.CompositionsBase.extensions]
    CompositionsBaseInverseFunctionsExt = "InverseFunctions"

[[deps.ComputationalResources]]
git-tree-sha1 = "52cb3ec90e8a8bea0e62e275ba577ad0f74821f7"
uuid = "ed09eef8-17a6-5b46-8889-db040fac31e3"
version = "0.3.2"

[[deps.ConcurrentUtilities]]
deps = ["Serialization", "Sockets"]
git-tree-sha1 = "87944e19ea747808b73178ce5ebb74081fdf2d35"
uuid = "f0e56b4a-5159-44fe-b623-3e5288b988bb"
version = "2.4.0"

[[deps.ConstructionBase]]
deps = ["LinearAlgebra"]
git-tree-sha1 = "c53fc348ca4d40d7b371e71fd52251839080cbc9"
uuid = "187b0558-2788-49d3-abe0-74a17ed4e7c9"
version = "1.5.4"
weakdeps = ["IntervalSets", "StaticArrays"]

    [deps.ConstructionBase.extensions]
    ConstructionBaseIntervalSetsExt = "IntervalSets"
    ConstructionBaseStaticArraysExt = "StaticArrays"

[[deps.ContextVariablesX]]
deps = ["Compat", "Logging", "UUIDs"]
git-tree-sha1 = "25cc3803f1030ab855e383129dcd3dc294e322cc"
uuid = "6add18c4-b38d-439d-96f6-d6bc489c04c5"
version = "0.1.3"

[[deps.Contour]]
git-tree-sha1 = "d05d9e7b7aedff4e5b51a029dced05cfb6125781"
uuid = "d38c429a-6771-53c6-b99e-75d170b6e991"
version = "0.6.2"

[[deps.CoordinateTransformations]]
deps = ["LinearAlgebra", "StaticArrays"]
git-tree-sha1 = "f9d7112bfff8a19a3a4ea4e03a8e6a91fe8456bf"
uuid = "150eb455-5306-5404-9cee-2592286d6298"
version = "0.6.3"

[[deps.CpuId]]
deps = ["Markdown"]
git-tree-sha1 = "fcbb72b032692610bfbdb15018ac16a36cf2e406"
uuid = "adafc99b-e345-5852-983c-f28acb93d879"
version = "0.3.1"

[[deps.Crayons]]
git-tree-sha1 = "249fe38abf76d48563e2f4556bebd215aa317e15"
uuid = "a8cc5b0e-0ffa-5ad4-8c14-923d3ee1735f"
version = "4.1.1"

[[deps.CustomUnitRanges]]
git-tree-sha1 = "1a3f97f907e6dd8983b744d2642651bb162a3f7a"
uuid = "dc8bdbbb-1ca9-579f-8c36-e416f6a65cce"
version = "1.0.2"

[[deps.DataAPI]]
git-tree-sha1 = "abe83f3a2f1b857aac70ef8b269080af17764bbe"
uuid = "9a962f9c-6df0-11e9-0e5d-c546b8b5ee8a"
version = "1.16.0"

[[deps.DataFrames]]
deps = ["Compat", "DataAPI", "DataStructures", "Future", "InlineStrings", "InvertedIndices", "IteratorInterfaceExtensions", "LinearAlgebra", "Markdown", "Missings", "PooledArrays", "PrecompileTools", "PrettyTables", "Printf", "REPL", "Random", "Reexport", "SentinelArrays", "SortingAlgorithms", "Statistics", "TableTraits", "Tables", "Unicode"]
git-tree-sha1 = "04c738083f29f86e62c8afc341f0967d8717bdb8"
uuid = "a93c6f00-e57d-5684-b7b6-d8193f3e46c0"
version = "1.6.1"

[[deps.DataStructures]]
deps = ["Compat", "InteractiveUtils", "OrderedCollections"]
git-tree-sha1 = "0f4b5d62a88d8f59003e43c25a8a90de9eb76317"
uuid = "864edb3b-99cc-5e75-8d2d-829cb0a9cfe8"
version = "0.18.18"

[[deps.DataValueInterfaces]]
git-tree-sha1 = "bfc1187b79289637fa0ef6d4436ebdfe6905cbd6"
uuid = "e2d170a0-9d28-54be-80f0-106bbe20a464"
version = "1.0.0"

[[deps.Dates]]
deps = ["Printf"]
uuid = "ade2ca70-3891-5945-98fb-dc099432e06a"

[[deps.DefineSingletons]]
git-tree-sha1 = "0fba8b706d0178b4dc7fd44a96a92382c9065c2c"
uuid = "244e2a9f-e319-4986-a169-4d1fe445cd52"
version = "0.1.2"

[[deps.DelimitedFiles]]
deps = ["Mmap"]
git-tree-sha1 = "9e2f36d3c96a820c678f2f1f1782582fcf685bae"
uuid = "8bb1440f-4735-579b-a4ab-409b98df4dab"
version = "1.9.1"

[[deps.DensityInterface]]
deps = ["InverseFunctions", "Test"]
git-tree-sha1 = "80c3e8639e3353e5d2912fb3a1916b8455e2494b"
uuid = "b429d917-457f-4dbc-8f4c-0cc954292b1d"
version = "0.4.0"

[[deps.DiffResults]]
deps = ["StaticArraysCore"]
git-tree-sha1 = "782dd5f4561f5d267313f23853baaaa4c52ea621"
uuid = "163ba53b-c6d8-5494-b064-1a9d43ac40c5"
version = "1.1.0"

[[deps.DiffRules]]
deps = ["IrrationalConstants", "LogExpFunctions", "NaNMath", "Random", "SpecialFunctions"]
git-tree-sha1 = "23163d55f885173722d1e4cf0f6110cdbaf7e272"
uuid = "b552c78f-8df3-52c6-915a-8e097449b14b"
version = "1.15.1"

[[deps.DifferentiableFrankWolfe]]
deps = ["ChainRulesCore", "FrankWolfe", "ImplicitDifferentiation", "LinearAlgebra"]
git-tree-sha1 = "6ee21e635eb1efb2182ba277828a35c555b7ede2"
uuid = "b383313e-5450-4164-a800-befbd27b574d"
version = "0.2.1"

[[deps.Distances]]
deps = ["LinearAlgebra", "Statistics", "StatsAPI"]
git-tree-sha1 = "66c4c81f259586e8f002eacebc177e1fb06363b0"
uuid = "b4f34e82-e78d-54a5-968a-f98e89d6e8f7"
version = "0.10.11"
weakdeps = ["ChainRulesCore", "SparseArrays"]

    [deps.Distances.extensions]
    DistancesChainRulesCoreExt = "ChainRulesCore"
    DistancesSparseArraysExt = "SparseArrays"

[[deps.Distributed]]
deps = ["Random", "Serialization", "Sockets"]
uuid = "8ba89e20-285c-5b6f-9357-94700520ee1b"

[[deps.DocStringExtensions]]
deps = ["LibGit2"]
git-tree-sha1 = "2fb1e02f2b635d0845df5d7c167fec4dd739b00d"
uuid = "ffbed154-4ef7-542d-bbb7-c09d3a79fcae"
version = "0.9.3"

[[deps.Downloads]]
deps = ["ArgTools", "FileWatching", "LibCURL", "NetworkOptions"]
uuid = "f43a241f-c20a-4ad4-852c-f6b1247861c6"
version = "1.6.0"

[[deps.DualNumbers]]
deps = ["Calculus", "NaNMath", "SpecialFunctions"]
git-tree-sha1 = "5837a837389fccf076445fce071c8ddaea35a566"
uuid = "fa6b7ba4-c1ee-5f82-b5fc-ecf0adba8f74"
version = "0.6.8"

[[deps.EpollShim_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl"]
git-tree-sha1 = "8e9441ee83492030ace98f9789a654a6d0b1f643"
uuid = "2702e6a9-849d-5ed8-8c21-79e8b8f9ee43"
version = "0.0.20230411+0"

[[deps.ExceptionUnwrapping]]
deps = ["Test"]
git-tree-sha1 = "dcb08a0d93ec0b1cdc4af184b26b591e9695423a"
uuid = "460bff9d-24e4-43bc-9d9f-a8973cb893f4"
version = "0.1.10"

[[deps.Expat_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl"]
git-tree-sha1 = "4558ab818dcceaab612d1bb8c19cee87eda2b83c"
uuid = "2e619515-83b5-522b-bb60-26c02a35a201"
version = "2.5.0+0"

[[deps.ExprTools]]
git-tree-sha1 = "27415f162e6028e81c72b82ef756bf321213b6ec"
uuid = "e2ba6199-217a-4e67-a87a-7c52f15ade04"
version = "0.1.10"

[[deps.FFMPEG]]
deps = ["FFMPEG_jll"]
git-tree-sha1 = "b57e3acbe22f8484b4b5ff66a7499717fe1a9cc8"
uuid = "c87230d0-a227-11e9-1b43-d7ebe4e7570a"
version = "0.4.1"

[[deps.FFMPEG_jll]]
deps = ["Artifacts", "Bzip2_jll", "FreeType2_jll", "FriBidi_jll", "JLLWrappers", "LAME_jll", "Libdl", "Ogg_jll", "OpenSSL_jll", "Opus_jll", "PCRE2_jll", "Zlib_jll", "libaom_jll", "libass_jll", "libfdk_aac_jll", "libvorbis_jll", "x264_jll", "x265_jll"]
git-tree-sha1 = "466d45dc38e15794ec7d5d63ec03d776a9aff36e"
uuid = "b22a6f82-2f65-5046-a5b2-351ab43fb4e5"
version = "4.4.4+1"

[[deps.FFTViews]]
deps = ["CustomUnitRanges", "FFTW"]
git-tree-sha1 = "cbdf14d1e8c7c8aacbe8b19862e0179fd08321c2"
uuid = "4f61f5a4-77b1-5117-aa51-3ab5ef4ef0cd"
version = "0.3.2"

[[deps.FFTW]]
deps = ["AbstractFFTs", "FFTW_jll", "LinearAlgebra", "MKL_jll", "Preferences", "Reexport"]
git-tree-sha1 = "4820348781ae578893311153d69049a93d05f39d"
uuid = "7a1cc6ca-52ef-59f5-83cd-3a7055c09341"
version = "1.8.0"

[[deps.FFTW_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "c6033cc3892d0ef5bb9cd29b7f2f0331ea5184ea"
uuid = "f5851436-0d7a-5f13-b9de-f02708fd171a"
version = "3.3.10+0"

[[deps.FLoops]]
deps = ["BangBang", "Compat", "FLoopsBase", "InitialValues", "JuliaVariables", "MLStyle", "Serialization", "Setfield", "Transducers"]
git-tree-sha1 = "ffb97765602e3cbe59a0589d237bf07f245a8576"
uuid = "cc61a311-1640-44b5-9fba-1b764f453329"
version = "0.2.1"

[[deps.FLoopsBase]]
deps = ["ContextVariablesX"]
git-tree-sha1 = "656f7a6859be8673bf1f35da5670246b923964f7"
uuid = "b9860ae5-e623-471e-878b-f6a53c775ea6"
version = "0.1.1"

[[deps.FastClosures]]
git-tree-sha1 = "acebe244d53ee1b461970f8910c235b259e772ef"
uuid = "9aa1b823-49e4-5ca5-8b0f-3971ec8bab6a"
version = "0.3.2"

[[deps.FileIO]]
deps = ["Pkg", "Requires", "UUIDs"]
git-tree-sha1 = "c5c28c245101bd59154f649e19b038d15901b5dc"
uuid = "5789e2e9-d7fb-5bc7-8068-2c6fae9b9549"
version = "1.16.2"

[[deps.FilePathsBase]]
deps = ["Compat", "Dates", "Mmap", "Printf", "Test", "UUIDs"]
git-tree-sha1 = "9f00e42f8d99fdde64d40c8ea5d14269a2e2c1aa"
uuid = "48062228-2e41-5def-b9a4-89aafe57970f"
version = "0.9.21"

[[deps.FileWatching]]
uuid = "7b1f6079-737a-58dc-b8bc-7a2ca5c1b5ee"

[[deps.FillArrays]]
deps = ["LinearAlgebra", "Random", "SparseArrays", "Statistics"]
git-tree-sha1 = "7072f1e3e5a8be51d525d64f63d3ec1287ff2790"
uuid = "1a297f60-69ca-5386-bcde-b61e274b549b"
version = "0.13.11"

[[deps.FixedPointNumbers]]
deps = ["Statistics"]
git-tree-sha1 = "335bfdceacc84c5cdf16aadc768aa5ddfc5383cc"
uuid = "53c48c17-4a7d-5ca2-90c5-79b7896eea93"
version = "0.8.4"

[[deps.Flux]]
deps = ["Adapt", "ChainRulesCore", "Compat", "Functors", "LinearAlgebra", "MLUtils", "MacroTools", "NNlib", "OneHotArrays", "Optimisers", "Preferences", "ProgressLogging", "Random", "Reexport", "SparseArrays", "SpecialFunctions", "Statistics", "Zygote"]
git-tree-sha1 = "5a626d6ef24ae0a8590c22dc12096fb65eb66325"
uuid = "587475ba-b771-5e3f-ad9e-33799f191a9c"
version = "0.14.13"

    [deps.Flux.extensions]
    FluxAMDGPUExt = "AMDGPU"
    FluxCUDAExt = "CUDA"
    FluxCUDAcuDNNExt = ["CUDA", "cuDNN"]
    FluxMetalExt = "Metal"

    [deps.Flux.weakdeps]
    AMDGPU = "21141c5a-9bdb-4563-92ae-f87d6854732e"
    CUDA = "052768ef-5323-5732-b1bb-66c8b64840ba"
    Metal = "dde4c033-4e86-420c-a63e-0dd931031962"
    cuDNN = "02a925ec-e4fe-4b08-9a7e-0d78e3d38ccd"

[[deps.Fontconfig_jll]]
deps = ["Artifacts", "Bzip2_jll", "Expat_jll", "FreeType2_jll", "JLLWrappers", "Libdl", "Libuuid_jll", "Pkg", "Zlib_jll"]
git-tree-sha1 = "21efd19106a55620a188615da6d3d06cd7f6ee03"
uuid = "a3f928ae-7b40-5064-980b-68af3947d34b"
version = "2.13.93+0"

[[deps.Format]]
git-tree-sha1 = "f3cf88025f6d03c194d73f5d13fee9004a108329"
uuid = "1fa38f19-a742-5d3f-a2b9-30dd87b9d5f8"
version = "1.3.6"

[[deps.ForwardDiff]]
deps = ["CommonSubexpressions", "DiffResults", "DiffRules", "LinearAlgebra", "LogExpFunctions", "NaNMath", "Preferences", "Printf", "Random", "SpecialFunctions"]
git-tree-sha1 = "cf0fe81336da9fb90944683b8c41984b08793dad"
uuid = "f6369f11-7733-5829-9624-2563aa707210"
version = "0.10.36"
weakdeps = ["StaticArrays"]

    [deps.ForwardDiff.extensions]
    ForwardDiffStaticArraysExt = "StaticArrays"

[[deps.FrankWolfe]]
deps = ["Arpack", "GenericSchur", "Hungarian", "LinearAlgebra", "MathOptInterface", "Printf", "ProgressMeter", "Random", "Setfield", "SparseArrays", "TimerOutputs"]
git-tree-sha1 = "981d231ac53d61bf4fed6dacfb00c6c94dfa07be"
uuid = "f55ce6ea-fdc5-4628-88c5-0087fe54bd30"
version = "0.3.3"

[[deps.FreeType2_jll]]
deps = ["Artifacts", "Bzip2_jll", "JLLWrappers", "Libdl", "Zlib_jll"]
git-tree-sha1 = "d8db6a5a2fe1381c1ea4ef2cab7c69c2de7f9ea0"
uuid = "d7e528f0-a631-5988-bf34-fe36492bcfd7"
version = "2.13.1+0"

[[deps.FriBidi_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "aa31987c2ba8704e23c6c8ba8a4f769d5d7e4f91"
uuid = "559328eb-81f9-559d-9380-de523a88c83c"
version = "1.0.10+0"

[[deps.Functors]]
deps = ["LinearAlgebra"]
git-tree-sha1 = "8ae30e786837ce0a24f5e2186938bf3251ab94b2"
uuid = "d9f16b24-f501-4c13-a1f2-28368ffc5196"
version = "0.4.8"

[[deps.Future]]
deps = ["Random"]
uuid = "9fa8497b-333b-5362-9e8d-4d0656e87820"

[[deps.GLFW_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Libglvnd_jll", "Xorg_libXcursor_jll", "Xorg_libXi_jll", "Xorg_libXinerama_jll", "Xorg_libXrandr_jll"]
git-tree-sha1 = "ff38ba61beff76b8f4acad8ab0c97ef73bb670cb"
uuid = "0656b61e-2033-5cc2-a64a-77c0f6c09b89"
version = "3.3.9+0"

[[deps.GPUArrays]]
deps = ["Adapt", "GPUArraysCore", "LLVM", "LinearAlgebra", "Printf", "Random", "Reexport", "Serialization", "Statistics"]
git-tree-sha1 = "47e4686ec18a9620850bad110b79966132f14283"
uuid = "0c68f7d7-f131-5f86-a1c3-88cf8149b2d7"
version = "10.0.2"

[[deps.GPUArraysCore]]
deps = ["Adapt"]
git-tree-sha1 = "ec632f177c0d990e64d955ccc1b8c04c485a0950"
uuid = "46192b85-c4d5-4398-a991-12ede77f4527"
version = "0.1.6"

[[deps.GPUCompiler]]
deps = ["ExprTools", "InteractiveUtils", "LLVM", "Libdl", "Logging", "Scratch", "TimerOutputs", "UUIDs"]
git-tree-sha1 = "a846f297ce9d09ccba02ead0cae70690e072a119"
uuid = "61eb1bfa-7361-4325-ad38-22787b887f55"
version = "0.25.0"

[[deps.GR]]
deps = ["Artifacts", "Base64", "DelimitedFiles", "Downloads", "GR_jll", "HTTP", "JSON", "Libdl", "LinearAlgebra", "Pkg", "Preferences", "Printf", "Random", "Serialization", "Sockets", "TOML", "Tar", "Test", "UUIDs", "p7zip_jll"]
git-tree-sha1 = "3437ade7073682993e092ca570ad68a2aba26983"
uuid = "28b8d3ca-fb5f-59d9-8090-bfdbd6d07a71"
version = "0.73.3"

[[deps.GR_jll]]
deps = ["Artifacts", "Bzip2_jll", "Cairo_jll", "FFMPEG_jll", "Fontconfig_jll", "FreeType2_jll", "GLFW_jll", "JLLWrappers", "JpegTurbo_jll", "Libdl", "Libtiff_jll", "Pixman_jll", "Qt6Base_jll", "Zlib_jll", "libpng_jll"]
git-tree-sha1 = "a96d5c713e6aa28c242b0d25c1347e258d6541ab"
uuid = "d2c73de3-f751-5644-a686-071e5b155ba9"
version = "0.73.3+0"

[[deps.GenericSchur]]
deps = ["LinearAlgebra", "Printf"]
git-tree-sha1 = "fb69b2a645fa69ba5f474af09221b9308b160ce6"
uuid = "c145ed77-6b09-5dd9-b285-bf645a82121e"
version = "0.5.3"

[[deps.Gettext_jll]]
deps = ["Artifacts", "CompilerSupportLibraries_jll", "JLLWrappers", "Libdl", "Libiconv_jll", "Pkg", "XML2_jll"]
git-tree-sha1 = "9b02998aba7bf074d14de89f9d37ca24a1a0b046"
uuid = "78b55507-aeef-58d4-861c-77aaff3498b1"
version = "0.21.0+0"

[[deps.Ghostscript_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "43ba3d3c82c18d88471cfd2924931658838c9d8f"
uuid = "61579ee1-b43e-5ca0-a5da-69d92c66a64b"
version = "9.55.0+4"

[[deps.Glib_jll]]
deps = ["Artifacts", "Gettext_jll", "JLLWrappers", "Libdl", "Libffi_jll", "Libiconv_jll", "Libmount_jll", "PCRE2_jll", "Zlib_jll"]
git-tree-sha1 = "359a1ba2e320790ddbe4ee8b4d54a305c0ea2aff"
uuid = "7746bdde-850d-59dc-9ae8-88ece973131d"
version = "2.80.0+0"

[[deps.Graphics]]
deps = ["Colors", "LinearAlgebra", "NaNMath"]
git-tree-sha1 = "d61890399bc535850c4bf08e4e0d3a7ad0f21cbd"
uuid = "a2bd30eb-e257-5431-a919-1863eab51364"
version = "1.1.2"

[[deps.Graphite2_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "344bf40dcab1073aca04aa0df4fb092f920e4011"
uuid = "3b182d85-2403-5c21-9c21-1e1f0cc25472"
version = "1.3.14+0"

[[deps.Graphs]]
deps = ["ArnoldiMethod", "Compat", "DataStructures", "Distributed", "Inflate", "LinearAlgebra", "Random", "SharedArrays", "SimpleTraits", "SparseArrays", "Statistics"]
git-tree-sha1 = "899050ace26649433ef1af25bc17a815b3db52b7"
uuid = "86223c79-3864-5bf0-83f7-82e725a168b6"
version = "1.9.0"

[[deps.GridGraphs]]
deps = ["DataStructures", "FillArrays", "Graphs", "SparseArrays"]
git-tree-sha1 = "84145cbcffc84c0d60099c6ac7c989885139bf09"
uuid = "dd2b58c7-5af7-4f17-9e46-57c68ac813fb"
version = "0.10.0"

[[deps.Grisu]]
git-tree-sha1 = "53bb909d1151e57e2484c3d1b53e19552b887fb2"
uuid = "42e2da0e-8278-4e71-bc24-59509adca0fe"
version = "1.0.2"

[[deps.HTTP]]
deps = ["Base64", "CodecZlib", "ConcurrentUtilities", "Dates", "ExceptionUnwrapping", "Logging", "LoggingExtras", "MbedTLS", "NetworkOptions", "OpenSSL", "Random", "SimpleBufferStream", "Sockets", "URIs", "UUIDs"]
git-tree-sha1 = "db864f2d91f68a5912937af80327d288ea1f3aee"
uuid = "cd3eb016-35fb-5094-929b-558a96fad6f3"
version = "1.10.3"

[[deps.HarfBuzz_jll]]
deps = ["Artifacts", "Cairo_jll", "Fontconfig_jll", "FreeType2_jll", "Glib_jll", "Graphite2_jll", "JLLWrappers", "Libdl", "Libffi_jll", "Pkg"]
git-tree-sha1 = "129acf094d168394e80ee1dc4bc06ec835e510a3"
uuid = "2e76f6c2-a576-52d4-95c1-20adfe4de566"
version = "2.8.1+1"

[[deps.HistogramThresholding]]
deps = ["ImageBase", "LinearAlgebra", "MappedArrays"]
git-tree-sha1 = "7194dfbb2f8d945abdaf68fa9480a965d6661e69"
uuid = "2c695a8d-9458-5d45-9878-1b8a99cf7853"
version = "0.3.1"

[[deps.HostCPUFeatures]]
deps = ["BitTwiddlingConvenienceFunctions", "IfElse", "Libdl", "Static"]
git-tree-sha1 = "eb8fed28f4994600e29beef49744639d985a04b2"
uuid = "3e5b6fbb-0976-4d2c-9146-d79de83f2fb0"
version = "0.1.16"

[[deps.Hungarian]]
deps = ["LinearAlgebra", "SparseArrays"]
git-tree-sha1 = "4f84db415ccb0ea750b10738bfecdd55388fd1b6"
uuid = "e91730f6-4275-51fb-a7a0-7064cfbd3b39"
version = "0.7.0"

[[deps.HypergeometricFunctions]]
deps = ["DualNumbers", "LinearAlgebra", "OpenLibm_jll", "SpecialFunctions"]
git-tree-sha1 = "f218fe3736ddf977e0e772bc9a586b2383da2685"
uuid = "34004b35-14d8-5ef3-9330-4cdb6864b03a"
version = "0.3.23"

[[deps.Hyperscript]]
deps = ["Test"]
git-tree-sha1 = "179267cfa5e712760cd43dcae385d7ea90cc25a4"
uuid = "47d2ed2b-36de-50cf-bf87-49c2cf4b8b91"
version = "0.0.5"

[[deps.HypertextLiteral]]
deps = ["Tricks"]
git-tree-sha1 = "7134810b1afce04bbc1045ca1985fbe81ce17653"
uuid = "ac1192a8-f4b3-4bfe-ba22-af5b92cd3ab2"
version = "0.9.5"

[[deps.IOCapture]]
deps = ["Logging", "Random"]
git-tree-sha1 = "8b72179abc660bfab5e28472e019392b97d0985c"
uuid = "b5f81e59-6552-4d32-b1f0-c071b021bf89"
version = "0.2.4"

[[deps.IRTools]]
deps = ["InteractiveUtils", "MacroTools", "Test"]
git-tree-sha1 = "5d8c5713f38f7bc029e26627b687710ba406d0dd"
uuid = "7869d1d1-7146-5819-86e3-90919afe41df"
version = "0.4.12"

[[deps.IfElse]]
git-tree-sha1 = "debdd00ffef04665ccbb3e150747a77560e8fad1"
uuid = "615f187c-cbe4-4ef1-ba3b-2fcf58d6d173"
version = "0.1.1"

[[deps.ImageAxes]]
deps = ["AxisArrays", "ImageBase", "ImageCore", "Reexport", "SimpleTraits"]
git-tree-sha1 = "2e4520d67b0cef90865b3ef727594d2a58e0e1f8"
uuid = "2803e5a7-5153-5ecf-9a86-9b4c37f5f5ac"
version = "0.6.11"

[[deps.ImageBase]]
deps = ["ImageCore", "Reexport"]
git-tree-sha1 = "b51bb8cae22c66d0f6357e3bcb6363145ef20835"
uuid = "c817782e-172a-44cc-b673-b171935fbb9e"
version = "0.1.5"

[[deps.ImageBinarization]]
deps = ["HistogramThresholding", "ImageCore", "LinearAlgebra", "Polynomials", "Reexport", "Statistics"]
git-tree-sha1 = "f5356e7203c4a9954962e3757c08033f2efe578a"
uuid = "cbc4b850-ae4b-5111-9e64-df94c024a13d"
version = "0.3.0"

[[deps.ImageContrastAdjustment]]
deps = ["ImageBase", "ImageCore", "ImageTransformations", "Parameters"]
git-tree-sha1 = "eb3d4365a10e3f3ecb3b115e9d12db131d28a386"
uuid = "f332f351-ec65-5f6a-b3d1-319c6670881a"
version = "0.3.12"

[[deps.ImageCore]]
deps = ["AbstractFFTs", "ColorVectorSpace", "Colors", "FixedPointNumbers", "Graphics", "MappedArrays", "MosaicViews", "OffsetArrays", "PaddedViews", "Reexport"]
git-tree-sha1 = "acf614720ef026d38400b3817614c45882d75500"
uuid = "a09fc81d-aa75-5fe9-8630-4744c3626534"
version = "0.9.4"

[[deps.ImageCorners]]
deps = ["ImageCore", "ImageFiltering", "PrecompileTools", "StaticArrays", "StatsBase"]
git-tree-sha1 = "24c52de051293745a9bad7d73497708954562b79"
uuid = "89d5987c-236e-4e32-acd0-25bd6bd87b70"
version = "0.1.3"

[[deps.ImageDistances]]
deps = ["Distances", "ImageCore", "ImageMorphology", "LinearAlgebra", "Statistics"]
git-tree-sha1 = "08b0e6354b21ef5dd5e49026028e41831401aca8"
uuid = "51556ac3-7006-55f5-8cb3-34580c88182d"
version = "0.2.17"

[[deps.ImageFiltering]]
deps = ["CatIndices", "ComputationalResources", "DataStructures", "FFTViews", "FFTW", "ImageBase", "ImageCore", "LinearAlgebra", "OffsetArrays", "PrecompileTools", "Reexport", "SparseArrays", "StaticArrays", "Statistics", "TiledIteration"]
git-tree-sha1 = "3447781d4c80dbe6d71d239f7cfb1f8049d4c84f"
uuid = "6a3955dd-da59-5b1f-98d4-e7296123deb5"
version = "0.7.6"

[[deps.ImageIO]]
deps = ["FileIO", "IndirectArrays", "JpegTurbo", "LazyModules", "Netpbm", "OpenEXR", "PNGFiles", "QOI", "Sixel", "TiffImages", "UUIDs"]
git-tree-sha1 = "bca20b2f5d00c4fbc192c3212da8fa79f4688009"
uuid = "82e4d734-157c-48bb-816b-45c225c6df19"
version = "0.6.7"

[[deps.ImageMagick]]
deps = ["FileIO", "ImageCore", "ImageMagick_jll", "InteractiveUtils", "Libdl", "Pkg", "Random"]
git-tree-sha1 = "5bc1cb62e0c5f1005868358db0692c994c3a13c6"
uuid = "6218d12a-5da1-5696-b52f-db25d2ecc6d1"
version = "1.2.1"

[[deps.ImageMagick_jll]]
deps = ["Artifacts", "Ghostscript_jll", "JLLWrappers", "JpegTurbo_jll", "Libdl", "Libtiff_jll", "OpenJpeg_jll", "Zlib_jll", "libpng_jll"]
git-tree-sha1 = "d65554bad8b16d9562050c67e7223abf91eaba2f"
uuid = "c73af94c-d91f-53ed-93a7-00f77d67a9d7"
version = "6.9.13+0"

[[deps.ImageMetadata]]
deps = ["AxisArrays", "ImageAxes", "ImageBase", "ImageCore"]
git-tree-sha1 = "355e2b974f2e3212a75dfb60519de21361ad3cb7"
uuid = "bc367c6b-8a6b-528e-b4bd-a4b897500b49"
version = "0.9.9"

[[deps.ImageMorphology]]
deps = ["DataStructures", "ImageCore", "LinearAlgebra", "LoopVectorization", "OffsetArrays", "Requires", "TiledIteration"]
git-tree-sha1 = "6f0a801136cb9c229aebea0df296cdcd471dbcd1"
uuid = "787d08f9-d448-5407-9aad-5290dd7ab264"
version = "0.4.5"

[[deps.ImageQualityIndexes]]
deps = ["ImageContrastAdjustment", "ImageCore", "ImageDistances", "ImageFiltering", "LazyModules", "OffsetArrays", "PrecompileTools", "Statistics"]
git-tree-sha1 = "783b70725ed326340adf225be4889906c96b8fd1"
uuid = "2996bd0c-7a13-11e9-2da2-2f5ce47296a9"
version = "0.3.7"

[[deps.ImageSegmentation]]
deps = ["Clustering", "DataStructures", "Distances", "Graphs", "ImageCore", "ImageFiltering", "ImageMorphology", "LinearAlgebra", "MetaGraphs", "RegionTrees", "SimpleWeightedGraphs", "StaticArrays", "Statistics"]
git-tree-sha1 = "44664eea5408828c03e5addb84fa4f916132fc26"
uuid = "80713f31-8817-5129-9cf8-209ff8fb23e1"
version = "1.8.1"

[[deps.ImageShow]]
deps = ["Base64", "ColorSchemes", "FileIO", "ImageBase", "ImageCore", "OffsetArrays", "StackViews"]
git-tree-sha1 = "3b5344bcdbdc11ad58f3b1956709b5b9345355de"
uuid = "4e3cecfd-b093-5904-9786-8bbb286a6a31"
version = "0.3.8"

[[deps.ImageTransformations]]
deps = ["AxisAlgorithms", "CoordinateTransformations", "ImageBase", "ImageCore", "Interpolations", "OffsetArrays", "Rotations", "StaticArrays"]
git-tree-sha1 = "e0884bdf01bbbb111aea77c348368a86fb4b5ab6"
uuid = "02fcd773-0e25-5acc-982a-7f6622650795"
version = "0.10.1"

[[deps.Images]]
deps = ["Base64", "FileIO", "Graphics", "ImageAxes", "ImageBase", "ImageBinarization", "ImageContrastAdjustment", "ImageCore", "ImageCorners", "ImageDistances", "ImageFiltering", "ImageIO", "ImageMagick", "ImageMetadata", "ImageMorphology", "ImageQualityIndexes", "ImageSegmentation", "ImageShow", "ImageTransformations", "IndirectArrays", "IntegralArrays", "Random", "Reexport", "SparseArrays", "StaticArrays", "Statistics", "StatsBase", "TiledIteration"]
git-tree-sha1 = "d438268ed7a665f8322572be0dabda83634d5f45"
uuid = "916415d5-f1e6-5110-898d-aaa5f9f070e0"
version = "0.26.0"

[[deps.Imath_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl"]
git-tree-sha1 = "3d09a9f60edf77f8a4d99f9e015e8fbf9989605d"
uuid = "905a6f67-0a94-5f89-b386-d35d92009cd1"
version = "3.1.7+0"

[[deps.ImplicitDifferentiation]]
deps = ["AbstractDifferentiation", "Krylov", "LinearAlgebra", "LinearOperators", "PrecompileTools", "Requires", "SimpleUnPack"]
git-tree-sha1 = "d9f3708b9ccac5a9bf3dd99d010a6ac0b537eb83"
uuid = "57b37032-215b-411a-8a7c-41a003a55207"
version = "0.5.2"
weakdeps = ["ChainRulesCore", "ForwardDiff", "StaticArrays", "Zygote"]

    [deps.ImplicitDifferentiation.extensions]
    ImplicitDifferentiationChainRulesCoreExt = "ChainRulesCore"
    ImplicitDifferentiationForwardDiffExt = "ForwardDiff"
    ImplicitDifferentiationStaticArraysExt = "StaticArrays"
    ImplicitDifferentiationZygoteExt = "Zygote"

[[deps.IndirectArrays]]
git-tree-sha1 = "012e604e1c7458645cb8b436f8fba789a51b257f"
uuid = "9b13fd28-a010-5f03-acff-a1bbcff69959"
version = "1.0.0"

[[deps.InferOpt]]
deps = ["ChainRulesCore", "DensityInterface", "LinearAlgebra", "Random", "RequiredInterfaces", "Statistics", "StatsBase", "StatsFuns", "ThreadsX"]
git-tree-sha1 = "cbe07b2683de4b1dd0c8def5e5f62ce97c60d24c"
uuid = "4846b161-c94e-4150-8dac-c7ae193c601f"
version = "0.6.1"
weakdeps = ["DifferentiableFrankWolfe"]

    [deps.InferOpt.extensions]
    InferOptFrankWolfeExt = "DifferentiableFrankWolfe"

[[deps.Inflate]]
git-tree-sha1 = "ea8031dea4aff6bd41f1df8f2fdfb25b33626381"
uuid = "d25df0c9-e2be-5dd7-82c8-3ad0b3e990b9"
version = "0.1.4"

[[deps.InitialValues]]
git-tree-sha1 = "4da0f88e9a39111c2fa3add390ab15f3a44f3ca3"
uuid = "22cec73e-a1b8-11e9-2c92-598750a2cf9c"
version = "0.3.1"

[[deps.InlineStrings]]
deps = ["Parsers"]
git-tree-sha1 = "9cc2baf75c6d09f9da536ddf58eb2f29dedaf461"
uuid = "842dd82b-1e85-43dc-bf29-5d0ee9dffc48"
version = "1.4.0"

[[deps.IntegralArrays]]
deps = ["ColorTypes", "FixedPointNumbers", "IntervalSets"]
git-tree-sha1 = "be8e690c3973443bec584db3346ddc904d4884eb"
uuid = "1d092043-8f09-5a30-832f-7509e371ab51"
version = "0.1.5"

[[deps.IntelOpenMP_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl"]
git-tree-sha1 = "5fdf2fe6724d8caabf43b557b84ce53f3b7e2f6b"
uuid = "1d5cc7b8-4909-519e-a0f8-d0f5ad9712d0"
version = "2024.0.2+0"

[[deps.InteractiveUtils]]
deps = ["Markdown"]
uuid = "b77e0a4c-d291-57a0-90e8-8db25a27a240"

[[deps.Interpolations]]
deps = ["Adapt", "AxisAlgorithms", "ChainRulesCore", "LinearAlgebra", "OffsetArrays", "Random", "Ratios", "Requires", "SharedArrays", "SparseArrays", "StaticArrays", "WoodburyMatrices"]
git-tree-sha1 = "88a101217d7cb38a7b481ccd50d21876e1d1b0e0"
uuid = "a98d9a8b-a2ab-59e6-89dd-64a1c18fca59"
version = "0.15.1"
weakdeps = ["Unitful"]

    [deps.Interpolations.extensions]
    InterpolationsUnitfulExt = "Unitful"

[[deps.IntervalSets]]
git-tree-sha1 = "dba9ddf07f77f60450fe5d2e2beb9854d9a49bd0"
uuid = "8197267c-284f-5f27-9208-e0e47529a953"
version = "0.7.10"
weakdeps = ["Random", "RecipesBase", "Statistics"]

    [deps.IntervalSets.extensions]
    IntervalSetsRandomExt = "Random"
    IntervalSetsRecipesBaseExt = "RecipesBase"
    IntervalSetsStatisticsExt = "Statistics"

[[deps.InverseFunctions]]
deps = ["Test"]
git-tree-sha1 = "68772f49f54b479fa88ace904f6127f0a3bb2e46"
uuid = "3587e190-3f89-42d0-90ee-14403ec27112"
version = "0.1.12"

[[deps.InvertedIndices]]
git-tree-sha1 = "0dc7b50b8d436461be01300fd8cd45aa0274b038"
uuid = "41ab1584-1d38-5bbf-9106-f11c6c58b48f"
version = "1.3.0"

[[deps.IrrationalConstants]]
git-tree-sha1 = "630b497eafcc20001bba38a4651b327dcfc491d2"
uuid = "92d709cd-6900-40b7-9082-c6be49f344b6"
version = "0.2.2"

[[deps.IterTools]]
git-tree-sha1 = "42d5f897009e7ff2cf88db414a389e5ed1bdd023"
uuid = "c8e1da08-722c-5040-9ed9-7db0dc04731e"
version = "1.10.0"

[[deps.IteratorInterfaceExtensions]]
git-tree-sha1 = "a3f24677c21f5bbe9d2a714f95dcd58337fb2856"
uuid = "82899510-4779-5014-852e-03e436cf321d"
version = "1.0.0"

[[deps.JLD2]]
deps = ["FileIO", "MacroTools", "Mmap", "OrderedCollections", "Pkg", "PrecompileTools", "Printf", "Reexport", "Requires", "TranscodingStreams", "UUIDs"]
git-tree-sha1 = "5ea6acdd53a51d897672edb694e3cc2912f3f8a7"
uuid = "033835bb-8acc-5ee8-8aae-3f567f8a3819"
version = "0.4.46"

[[deps.JLFzf]]
deps = ["Pipe", "REPL", "Random", "fzf_jll"]
git-tree-sha1 = "a53ebe394b71470c7f97c2e7e170d51df21b17af"
uuid = "1019f520-868f-41f5-a6de-eb00f4b6a39c"
version = "0.1.7"

[[deps.JLLWrappers]]
deps = ["Artifacts", "Preferences"]
git-tree-sha1 = "7e5d6779a1e09a36db2a7b6cff50942a0a7d0fca"
uuid = "692b3bcd-3c85-4b1f-b108-f13ce0eb3210"
version = "1.5.0"

[[deps.JSON]]
deps = ["Dates", "Mmap", "Parsers", "Unicode"]
git-tree-sha1 = "31e996f0a15c7b280ba9f76636b3ff9e2ae58c9a"
uuid = "682c06a0-de6a-54ab-a142-c8b1cf79cde6"
version = "0.21.4"

[[deps.JpegTurbo]]
deps = ["CEnum", "FileIO", "ImageCore", "JpegTurbo_jll", "TOML"]
git-tree-sha1 = "fa6d0bcff8583bac20f1ffa708c3913ca605c611"
uuid = "b835a17e-a41a-41e7-81f0-2f016b05efe0"
version = "0.1.5"

[[deps.JpegTurbo_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl"]
git-tree-sha1 = "3336abae9a713d2210bb57ab484b1e065edd7d23"
uuid = "aacddb02-875f-59d6-b918-886e6ef4fbf8"
version = "3.0.2+0"

[[deps.JuliaInterpreter]]
deps = ["CodeTracking", "InteractiveUtils", "Random", "UUIDs"]
git-tree-sha1 = "7b762d81887160169ddfc93a47e5fd7a6a3e78ef"
uuid = "aa1ae85d-cabe-5617-a682-6adf51b2e16a"
version = "0.9.29"

[[deps.JuliaNVTXCallbacks_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "af433a10f3942e882d3c671aacb203e006a5808f"
uuid = "9c1d0b0a-7046-5b2e-a33f-ea22f176ac7e"
version = "0.2.1+0"

[[deps.JuliaVariables]]
deps = ["MLStyle", "NameResolution"]
git-tree-sha1 = "49fb3cb53362ddadb4415e9b73926d6b40709e70"
uuid = "b14d175d-62b4-44ba-8fb7-3064adc8c3ec"
version = "0.2.4"

[[deps.KernelAbstractions]]
deps = ["Adapt", "Atomix", "InteractiveUtils", "LinearAlgebra", "MacroTools", "PrecompileTools", "Requires", "SparseArrays", "StaticArrays", "UUIDs", "UnsafeAtomics", "UnsafeAtomicsLLVM"]
git-tree-sha1 = "ed7167240f40e62d97c1f5f7735dea6de3cc5c49"
uuid = "63c18a36-062a-441e-b654-da1e3ab1ce7c"
version = "0.9.18"

    [deps.KernelAbstractions.extensions]
    EnzymeExt = "EnzymeCore"

    [deps.KernelAbstractions.weakdeps]
    EnzymeCore = "f151be2c-9106-41f4-ab19-57ee4f262869"

[[deps.Krylov]]
deps = ["LinearAlgebra", "Printf", "SparseArrays"]
git-tree-sha1 = "8a6837ec02fe5fb3def1abc907bb802ef11a0729"
uuid = "ba0b0d4f-ebba-5204-a429-3ac8c609bfb7"
version = "0.9.5"

[[deps.LAME_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "f6250b16881adf048549549fba48b1161acdac8c"
uuid = "c1c5ebd0-6772-5130-a774-d5fcae4a789d"
version = "3.100.1+0"

[[deps.LDLFactorizations]]
deps = ["AMD", "LinearAlgebra", "SparseArrays", "Test"]
git-tree-sha1 = "70f582b446a1c3ad82cf87e62b878668beef9d13"
uuid = "40e66cde-538c-5869-a4ad-c39174c6795b"
version = "0.10.1"

[[deps.LERC_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "bf36f528eec6634efc60d7ec062008f171071434"
uuid = "88015f11-f218-50d7-93a8-a6af411a945d"
version = "3.0.0+1"

[[deps.LLVM]]
deps = ["CEnum", "LLVMExtra_jll", "Libdl", "Preferences", "Printf", "Requires", "Unicode"]
git-tree-sha1 = "ddab4d40513bce53c8e3157825e245224f74fae7"
uuid = "929cbde3-209d-540e-8aea-75f648917ca0"
version = "6.6.0"
weakdeps = ["BFloat16s"]

    [deps.LLVM.extensions]
    BFloat16sExt = "BFloat16s"

[[deps.LLVMExtra_jll]]
deps = ["Artifacts", "JLLWrappers", "LazyArtifacts", "Libdl", "TOML"]
git-tree-sha1 = "88b916503aac4fb7f701bb625cd84ca5dd1677bc"
uuid = "dad2f222-ce93-54a1-a47d-0025e8a3acab"
version = "0.0.29+0"

[[deps.LLVMLoopInfo]]
git-tree-sha1 = "2e5c102cfc41f48ae4740c7eca7743cc7e7b75ea"
uuid = "8b046642-f1f6-4319-8d3c-209ddc03c586"
version = "1.0.0"

[[deps.LLVMOpenMP_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl"]
git-tree-sha1 = "d986ce2d884d49126836ea94ed5bfb0f12679713"
uuid = "1d63c593-3942-5779-bab2-d838dc0a180e"
version = "15.0.7+0"

[[deps.LZO_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "e5b909bcf985c5e2605737d2ce278ed791b89be6"
uuid = "dd4b983a-f0e5-5f8d-a1b7-129d4a5fb1ac"
version = "2.10.1+0"

[[deps.LaTeXStrings]]
git-tree-sha1 = "50901ebc375ed41dbf8058da26f9de442febbbec"
uuid = "b964fa9f-0449-5b57-a5c2-d3ea65f4040f"
version = "1.3.1"

[[deps.Latexify]]
deps = ["Format", "InteractiveUtils", "LaTeXStrings", "MacroTools", "Markdown", "OrderedCollections", "Requires"]
git-tree-sha1 = "cad560042a7cc108f5a4c24ea1431a9221f22c1b"
uuid = "23fbe1c1-3f47-55db-b15f-69d7ec21a316"
version = "0.16.2"

    [deps.Latexify.extensions]
    DataFramesExt = "DataFrames"
    SymEngineExt = "SymEngine"

    [deps.Latexify.weakdeps]
    DataFrames = "a93c6f00-e57d-5684-b7b6-d8193f3e46c0"
    SymEngine = "123dc426-2d89-5057-bbad-38513e3affd8"

[[deps.LayoutPointers]]
deps = ["ArrayInterface", "LinearAlgebra", "ManualMemory", "SIMDTypes", "Static", "StaticArrayInterface"]
git-tree-sha1 = "62edfee3211981241b57ff1cedf4d74d79519277"
uuid = "10f19ff3-798f-405d-979b-55457f8fc047"
version = "0.1.15"

[[deps.LazyArtifacts]]
deps = ["Artifacts", "Pkg"]
uuid = "4af54fe1-eca0-43a8-85a7-787d91b784e3"

[[deps.LazyModules]]
git-tree-sha1 = "a560dd966b386ac9ae60bdd3a3d3a326062d3c3e"
uuid = "8cdb02fc-e678-4876-92c5-9defec4f444e"
version = "0.3.1"

[[deps.LibCURL]]
deps = ["LibCURL_jll", "MozillaCACerts_jll"]
uuid = "b27032c2-a3e7-50c8-80cd-2d36dbcbfd21"
version = "0.6.4"

[[deps.LibCURL_jll]]
deps = ["Artifacts", "LibSSH2_jll", "Libdl", "MbedTLS_jll", "Zlib_jll", "nghttp2_jll"]
uuid = "deac9b47-8bc7-5906-a0fe-35ac56dc84c0"
version = "8.4.0+0"

[[deps.LibGit2]]
deps = ["Base64", "LibGit2_jll", "NetworkOptions", "Printf", "SHA"]
uuid = "76f85450-5226-5b5a-8eaa-529ad045b433"

[[deps.LibGit2_jll]]
deps = ["Artifacts", "LibSSH2_jll", "Libdl", "MbedTLS_jll"]
uuid = "e37daf67-58a4-590a-8e99-b0245dd2ffc5"
version = "1.6.4+0"

[[deps.LibSSH2_jll]]
deps = ["Artifacts", "Libdl", "MbedTLS_jll"]
uuid = "29816b5a-b9ab-546f-933c-edad1886dfa8"
version = "1.11.0+1"

[[deps.Libdl]]
uuid = "8f399da3-3557-5675-b5ff-fb832c97cbdb"

[[deps.Libffi_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "0b4a5d71f3e5200a7dff793393e09dfc2d874290"
uuid = "e9f186c6-92d2-5b65-8a66-fee21dc1b490"
version = "3.2.2+1"

[[deps.Libgcrypt_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Libgpg_error_jll", "Pkg"]
git-tree-sha1 = "64613c82a59c120435c067c2b809fc61cf5166ae"
uuid = "d4300ac3-e22c-5743-9152-c294e39db1e4"
version = "1.8.7+0"

[[deps.Libglvnd_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg", "Xorg_libX11_jll", "Xorg_libXext_jll"]
git-tree-sha1 = "6f73d1dd803986947b2c750138528a999a6c7733"
uuid = "7e76a0d4-f3c7-5321-8279-8d96eeed0f29"
version = "1.6.0+0"

[[deps.Libgpg_error_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "c333716e46366857753e273ce6a69ee0945a6db9"
uuid = "7add5ba3-2f88-524e-9cd5-f83b8a55f7b8"
version = "1.42.0+0"

[[deps.Libiconv_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl"]
git-tree-sha1 = "f9557a255370125b405568f9767d6d195822a175"
uuid = "94ce4f54-9a6c-5748-9c1c-f9c7231a4531"
version = "1.17.0+0"

[[deps.Libmount_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl"]
git-tree-sha1 = "dae976433497a2f841baadea93d27e68f1a12a97"
uuid = "4b2f31a3-9ecc-558c-b454-b3730dcb73e9"
version = "2.39.3+0"

[[deps.Libtiff_jll]]
deps = ["Artifacts", "JLLWrappers", "JpegTurbo_jll", "LERC_jll", "Libdl", "XZ_jll", "Zlib_jll", "Zstd_jll"]
git-tree-sha1 = "2da088d113af58221c52828a80378e16be7d037a"
uuid = "89763e89-9b03-5906-acba-b20f662cd828"
version = "4.5.1+1"

[[deps.Libuuid_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl"]
git-tree-sha1 = "0a04a1318df1bf510beb2562cf90fb0c386f58c4"
uuid = "38a345b3-de98-5d2b-a5d3-14cd9215e700"
version = "2.39.3+1"

[[deps.LinearAlgebra]]
deps = ["Libdl", "OpenBLAS_jll", "libblastrampoline_jll"]
uuid = "37e2e46d-f89d-539d-b4ee-838fcccc9c8e"

[[deps.LinearOperators]]
deps = ["FastClosures", "LDLFactorizations", "LinearAlgebra", "Printf", "Requires", "SparseArrays", "TimerOutputs"]
git-tree-sha1 = "f06df3a46255879cbccae1b5b6dcb16994c31be7"
uuid = "5c8ed15e-5a4c-59e4-a42b-c7e8811fb125"
version = "2.7.0"
weakdeps = ["ChainRulesCore"]

    [deps.LinearOperators.extensions]
    LinearOperatorsChainRulesCoreExt = "ChainRulesCore"

[[deps.LittleCMS_jll]]
deps = ["Artifacts", "JLLWrappers", "JpegTurbo_jll", "Libdl", "Libtiff_jll"]
git-tree-sha1 = "08ed30575ffc5651a50d3291beaf94c3e7996e55"
uuid = "d3a379c0-f9a3-5b72-a4c0-6bf4d2e8af0f"
version = "2.15.0+0"

[[deps.LogExpFunctions]]
deps = ["DocStringExtensions", "IrrationalConstants", "LinearAlgebra"]
git-tree-sha1 = "18144f3e9cbe9b15b070288eef858f71b291ce37"
uuid = "2ab3a3ac-af41-5b50-aa03-7779005ae688"
version = "0.3.27"

    [deps.LogExpFunctions.extensions]
    LogExpFunctionsChainRulesCoreExt = "ChainRulesCore"
    LogExpFunctionsChangesOfVariablesExt = "ChangesOfVariables"
    LogExpFunctionsInverseFunctionsExt = "InverseFunctions"

    [deps.LogExpFunctions.weakdeps]
    ChainRulesCore = "d360d2e6-b24c-11e9-a2a3-2a2ae2dbcce4"
    ChangesOfVariables = "9e997f8a-9a97-42d5-a9f1-ce6bfc15e2c0"
    InverseFunctions = "3587e190-3f89-42d0-90ee-14403ec27112"

[[deps.Logging]]
uuid = "56ddb016-857b-54e1-b83d-db4d58db5568"

[[deps.LoggingExtras]]
deps = ["Dates", "Logging"]
git-tree-sha1 = "c1dd6d7978c12545b4179fb6153b9250c96b0075"
uuid = "e6f89c97-d47a-5376-807f-9c37f3926c36"
version = "1.0.3"

[[deps.LoopVectorization]]
deps = ["ArrayInterface", "CPUSummary", "CloseOpenIntervals", "DocStringExtensions", "HostCPUFeatures", "IfElse", "LayoutPointers", "LinearAlgebra", "OffsetArrays", "PolyesterWeave", "PrecompileTools", "SIMDTypes", "SLEEFPirates", "Static", "StaticArrayInterface", "ThreadingUtilities", "UnPack", "VectorizationBase"]
git-tree-sha1 = "0f5648fbae0d015e3abe5867bca2b362f67a5894"
uuid = "bdcacae8-1622-11e9-2a5c-532679323890"
version = "0.12.166"
weakdeps = ["ChainRulesCore", "ForwardDiff", "SpecialFunctions"]

    [deps.LoopVectorization.extensions]
    ForwardDiffExt = ["ChainRulesCore", "ForwardDiff"]
    SpecialFunctionsExt = "SpecialFunctions"

[[deps.LoweredCodeUtils]]
deps = ["JuliaInterpreter"]
git-tree-sha1 = "31e27f0b0bf0df3e3e951bfcc43fe8c730a219f6"
uuid = "6f1432cf-f94c-5a45-995e-cdbf5db27b0b"
version = "2.4.5"

[[deps.MIMEs]]
git-tree-sha1 = "65f28ad4b594aebe22157d6fac869786a255b7eb"
uuid = "6c6e2e6c-3030-632d-7369-2d6c69616d65"
version = "0.1.4"

[[deps.MKL_jll]]
deps = ["Artifacts", "IntelOpenMP_jll", "JLLWrappers", "LazyArtifacts", "Libdl"]
git-tree-sha1 = "72dc3cf284559eb8f53aa593fe62cb33f83ed0c0"
uuid = "856f044c-d86e-5d09-b602-aeab76dc8ba7"
version = "2024.0.0+0"

[[deps.MLStyle]]
git-tree-sha1 = "bc38dff0548128765760c79eb7388a4b37fae2c8"
uuid = "d8e11817-5142-5d16-987a-aa16d5891078"
version = "0.4.17"

[[deps.MLUtils]]
deps = ["ChainRulesCore", "Compat", "DataAPI", "DelimitedFiles", "FLoops", "NNlib", "Random", "ShowCases", "SimpleTraits", "Statistics", "StatsBase", "Tables", "Transducers"]
git-tree-sha1 = "b45738c2e3d0d402dffa32b2c1654759a2ac35a4"
uuid = "f1d291b0-491e-4a28-83b9-f70985020b54"
version = "0.4.4"

[[deps.MacroTools]]
deps = ["Markdown", "Random"]
git-tree-sha1 = "2fa9ee3e63fd3a4f7a9a4f4744a52f4856de82df"
uuid = "1914dd2f-81c6-5fcd-8719-6d5c9610ff09"
version = "0.5.13"

[[deps.ManualMemory]]
git-tree-sha1 = "bcaef4fc7a0cfe2cba636d84cda54b5e4e4ca3cd"
uuid = "d125e4d3-2237-4719-b19c-fa641b8a4667"
version = "0.1.8"

[[deps.MappedArrays]]
git-tree-sha1 = "2dab0221fe2b0f2cb6754eaa743cc266339f527e"
uuid = "dbb5928d-eab1-5f90-85c2-b9b0edb7c900"
version = "0.4.2"

[[deps.MarchingCubes]]
deps = ["PrecompileTools", "StaticArrays"]
git-tree-sha1 = "27d162f37cc29de047b527dab11a826dd3a650ad"
uuid = "299715c1-40a9-479a-aaf9-4a633d36f717"
version = "0.1.9"

[[deps.Markdown]]
deps = ["Base64"]
uuid = "d6f4376e-aef5-505a-96c1-9c027394607a"

[[deps.MathOptInterface]]
deps = ["BenchmarkTools", "CodecBzip2", "CodecZlib", "DataStructures", "ForwardDiff", "JSON", "LinearAlgebra", "MutableArithmetics", "NaNMath", "OrderedCollections", "PrecompileTools", "Printf", "SparseArrays", "SpecialFunctions", "Test", "Unicode"]
git-tree-sha1 = "679c1aec6934d322783bd15db4d18f898653be4f"
uuid = "b8f27783-ece8-5eb3-8dc8-9495eed66fee"
version = "1.27.0"

[[deps.MbedTLS]]
deps = ["Dates", "MbedTLS_jll", "MozillaCACerts_jll", "NetworkOptions", "Random", "Sockets"]
git-tree-sha1 = "c067a280ddc25f196b5e7df3877c6b226d390aaf"
uuid = "739be429-bea8-5141-9913-cc70e7f3736d"
version = "1.1.9"

[[deps.MbedTLS_jll]]
deps = ["Artifacts", "Libdl"]
uuid = "c8ffd9c3-330d-5841-b78e-0817d7145fa1"
version = "2.28.2+1"

[[deps.Measures]]
git-tree-sha1 = "c13304c81eec1ed3af7fc20e75fb6b26092a1102"
uuid = "442fdcdd-2543-5da2-b0f3-8c86c306513e"
version = "0.3.2"

[[deps.MetaGraphs]]
deps = ["Graphs", "JLD2", "Random"]
git-tree-sha1 = "1130dbe1d5276cb656f6e1094ce97466ed700e5a"
uuid = "626554b9-1ddb-594c-aa3c-2596fe9399a5"
version = "0.7.2"

[[deps.Metalhead]]
deps = ["Artifacts", "BSON", "ChainRulesCore", "Flux", "Functors", "JLD2", "LazyArtifacts", "MLUtils", "NNlib", "PartialFunctions", "Random", "Statistics"]
git-tree-sha1 = "5aac9a2b511afda7bf89df5044a2e0b429f83152"
uuid = "dbeba491-748d-5e0e-a39e-b530a07fa0cc"
version = "0.9.3"
weakdeps = ["CUDA"]

    [deps.Metalhead.extensions]
    MetalheadCUDAExt = "CUDA"

[[deps.MicroCollections]]
deps = ["BangBang", "InitialValues", "Setfield"]
git-tree-sha1 = "629afd7d10dbc6935ec59b32daeb33bc4460a42e"
uuid = "128add7d-3638-4c79-886c-908ea0c25c34"
version = "0.1.4"

[[deps.Missings]]
deps = ["DataAPI"]
git-tree-sha1 = "f66bdc5de519e8f8ae43bdc598782d35a25b1272"
uuid = "e1d29d7a-bbdc-5cf2-9ac0-f12de2c33e28"
version = "1.1.0"

[[deps.Mmap]]
uuid = "a63ad114-7e13-5084-954f-fe012c677804"

[[deps.MosaicViews]]
deps = ["MappedArrays", "OffsetArrays", "PaddedViews", "StackViews"]
git-tree-sha1 = "7b86a5d4d70a9f5cdf2dacb3cbe6d251d1a61dbe"
uuid = "e94cdb99-869f-56ef-bcf0-1ae2bcbe0389"
version = "0.3.4"

[[deps.MozillaCACerts_jll]]
uuid = "14a3606d-f60d-562e-9121-12d972cd8159"
version = "2023.1.10"

[[deps.MutableArithmetics]]
deps = ["LinearAlgebra", "SparseArrays", "Test"]
git-tree-sha1 = "302fd161eb1c439e4115b51ae456da4e9984f130"
uuid = "d8a4904e-b15c-11e9-3269-09a3773c0cb0"
version = "1.4.1"

[[deps.NNlib]]
deps = ["Adapt", "Atomix", "ChainRulesCore", "GPUArraysCore", "KernelAbstractions", "LinearAlgebra", "Pkg", "Random", "Requires", "Statistics"]
git-tree-sha1 = "877f15c331337d54cf24c797d5bcb2e48ce21221"
uuid = "872c559c-99b0-510c-b3b7-b6c96a88d5cd"
version = "0.9.12"

    [deps.NNlib.extensions]
    NNlibAMDGPUExt = "AMDGPU"
    NNlibCUDACUDNNExt = ["CUDA", "cuDNN"]
    NNlibCUDAExt = "CUDA"
    NNlibEnzymeCoreExt = "EnzymeCore"

    [deps.NNlib.weakdeps]
    AMDGPU = "21141c5a-9bdb-4563-92ae-f87d6854732e"
    CUDA = "052768ef-5323-5732-b1bb-66c8b64840ba"
    EnzymeCore = "f151be2c-9106-41f4-ab19-57ee4f262869"
    cuDNN = "02a925ec-e4fe-4b08-9a7e-0d78e3d38ccd"

[[deps.NPZ]]
deps = ["FileIO", "ZipFile"]
git-tree-sha1 = "60a8e272fe0c5079363b28b0953831e2dd7b7e6f"
uuid = "15e1cf62-19b3-5cfa-8e77-841668bca605"
version = "0.4.3"

[[deps.NVTX]]
deps = ["Colors", "JuliaNVTXCallbacks_jll", "Libdl", "NVTX_jll"]
git-tree-sha1 = "53046f0483375e3ed78e49190f1154fa0a4083a1"
uuid = "5da4648a-3479-48b8-97b9-01cb529c0a1f"
version = "0.3.4"

[[deps.NVTX_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "ce3269ed42816bf18d500c9f63418d4b0d9f5a3b"
uuid = "e98f9f5b-d649-5603-91fd-7774390e6439"
version = "3.1.0+2"

[[deps.NaNMath]]
deps = ["OpenLibm_jll"]
git-tree-sha1 = "0877504529a3e5c3343c6f8b4c0381e57e4387e4"
uuid = "77ba4419-2d1f-58cd-9bb1-8ffee604a2e3"
version = "1.0.2"

[[deps.NameResolution]]
deps = ["PrettyPrint"]
git-tree-sha1 = "1a0fa0e9613f46c9b8c11eee38ebb4f590013c5e"
uuid = "71a1bf82-56d0-4bbc-8a3c-48b961074391"
version = "0.1.5"

[[deps.NearestNeighbors]]
deps = ["Distances", "StaticArrays"]
git-tree-sha1 = "ded64ff6d4fdd1cb68dfcbb818c69e144a5b2e4c"
uuid = "b8a86587-4115-5ab1-83bc-aa920d37bbce"
version = "0.4.16"

[[deps.Netpbm]]
deps = ["FileIO", "ImageCore", "ImageMetadata"]
git-tree-sha1 = "d92b107dbb887293622df7697a2223f9f8176fcd"
uuid = "f09324ee-3d7c-5217-9330-fc30815ba969"
version = "1.1.1"

[[deps.NetworkOptions]]
uuid = "ca575930-c2e3-43a9-ace4-1e988b2c1908"
version = "1.2.0"

[[deps.OffsetArrays]]
git-tree-sha1 = "6a731f2b5c03157418a20c12195eb4b74c8f8621"
uuid = "6fe1bfb0-de20-5000-8ca7-80f57d26f881"
version = "1.13.0"
weakdeps = ["Adapt"]

    [deps.OffsetArrays.extensions]
    OffsetArraysAdaptExt = "Adapt"

[[deps.Ogg_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "887579a3eb005446d514ab7aeac5d1d027658b8f"
uuid = "e7412a2a-1a6e-54c0-be00-318e2571c051"
version = "1.3.5+1"

[[deps.OneHotArrays]]
deps = ["Adapt", "ChainRulesCore", "Compat", "GPUArraysCore", "LinearAlgebra", "NNlib"]
git-tree-sha1 = "963a3f28a2e65bb87a68033ea4a616002406037d"
uuid = "0b1bfda6-eb8a-41d2-88d8-f5af5cad476f"
version = "0.2.5"

[[deps.OpenBLAS_jll]]
deps = ["Artifacts", "CompilerSupportLibraries_jll", "Libdl"]
uuid = "4536629a-c528-5b80-bd46-f80d51c5b363"
version = "0.3.23+4"

[[deps.OpenEXR]]
deps = ["Colors", "FileIO", "OpenEXR_jll"]
git-tree-sha1 = "327f53360fdb54df7ecd01e96ef1983536d1e633"
uuid = "52e1d378-f018-4a11-a4be-720524705ac7"
version = "0.3.2"

[[deps.OpenEXR_jll]]
deps = ["Artifacts", "Imath_jll", "JLLWrappers", "Libdl", "Zlib_jll"]
git-tree-sha1 = "a4ca623df1ae99d09bc9868b008262d0c0ac1e4f"
uuid = "18a262bb-aa17-5467-a713-aee519bc75cb"
version = "3.1.4+0"

[[deps.OpenJpeg_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Libtiff_jll", "LittleCMS_jll", "libpng_jll"]
git-tree-sha1 = "8d4c87ffaf09dbdd82bcf8c939843e94dd424df2"
uuid = "643b3616-a352-519d-856d-80112ee9badc"
version = "2.5.0+0"

[[deps.OpenLibm_jll]]
deps = ["Artifacts", "Libdl"]
uuid = "05823500-19ac-5b8b-9628-191a04bc5112"
version = "0.8.1+2"

[[deps.OpenSSL]]
deps = ["BitFlags", "Dates", "MozillaCACerts_jll", "OpenSSL_jll", "Sockets"]
git-tree-sha1 = "af81a32750ebc831ee28bdaaba6e1067decef51e"
uuid = "4d8831e6-92b7-49fb-bdf8-b643e874388c"
version = "1.4.2"

[[deps.OpenSSL_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl"]
git-tree-sha1 = "60e3045590bd104a16fefb12836c00c0ef8c7f8c"
uuid = "458c3c95-2e84-50aa-8efc-19380b2a3a95"
version = "3.0.13+0"

[[deps.OpenSpecFun_jll]]
deps = ["Artifacts", "CompilerSupportLibraries_jll", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "13652491f6856acfd2db29360e1bbcd4565d04f1"
uuid = "efe28fd5-8261-553b-a9e1-b2916fc3738e"
version = "0.5.5+0"

[[deps.Optimisers]]
deps = ["ChainRulesCore", "Functors", "LinearAlgebra", "Random", "Statistics"]
git-tree-sha1 = "264b061c1903bc0fe9be77cb9050ebacff66bb63"
uuid = "3bd65402-5787-11e9-1adc-39752487f4e2"
version = "0.3.2"

[[deps.Opus_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "51a08fb14ec28da2ec7a927c4337e4332c2a4720"
uuid = "91d4177d-7536-5919-b921-800302f37372"
version = "1.3.2+0"

[[deps.OrderedCollections]]
git-tree-sha1 = "dfdf5519f235516220579f949664f1bf44e741c5"
uuid = "bac558e1-5e72-5ebc-8fee-abe8a469f55d"
version = "1.6.3"

[[deps.PCRE2_jll]]
deps = ["Artifacts", "Libdl"]
uuid = "efcefdf7-47ab-520b-bdef-62a2eaa19f15"
version = "10.42.0+1"

[[deps.PNGFiles]]
deps = ["Base64", "CEnum", "ImageCore", "IndirectArrays", "OffsetArrays", "libpng_jll"]
git-tree-sha1 = "67186a2bc9a90f9f85ff3cc8277868961fb57cbd"
uuid = "f57f5aa1-a3ce-4bc8-8ab9-96f992907883"
version = "0.4.3"

[[deps.PaddedViews]]
deps = ["OffsetArrays"]
git-tree-sha1 = "0fac6313486baae819364c52b4f483450a9d793f"
uuid = "5432bcbf-9aad-5242-b902-cca2824c8663"
version = "0.5.12"

[[deps.Parameters]]
deps = ["OrderedCollections", "UnPack"]
git-tree-sha1 = "34c0e9ad262e5f7fc75b10a9952ca7692cfc5fbe"
uuid = "d96e819e-fc66-5662-9728-84c9c7592b0a"
version = "0.12.3"

[[deps.Parsers]]
deps = ["Dates", "PrecompileTools", "UUIDs"]
git-tree-sha1 = "8489905bcdbcfac64d1daa51ca07c0d8f0283821"
uuid = "69de0a69-1ddd-5017-9359-2bf0b02dc9f0"
version = "2.8.1"

[[deps.PartialFunctions]]
deps = ["MacroTools"]
git-tree-sha1 = "47b49a4dbc23b76682205c646252c0f9e1eb75af"
uuid = "570af359-4316-4cb7-8c74-252c00c2016b"
version = "1.2.0"

[[deps.Pipe]]
git-tree-sha1 = "6842804e7867b115ca9de748a0cf6b364523c16d"
uuid = "b98c9c47-44ae-5843-9183-064241ee97a0"
version = "1.3.0"

[[deps.Pixman_jll]]
deps = ["Artifacts", "CompilerSupportLibraries_jll", "JLLWrappers", "LLVMOpenMP_jll", "Libdl"]
git-tree-sha1 = "64779bc4c9784fee475689a1752ef4d5747c5e87"
uuid = "30392449-352a-5448-841d-b1acce4e97dc"
version = "0.42.2+0"

[[deps.Pkg]]
deps = ["Artifacts", "Dates", "Downloads", "FileWatching", "LibGit2", "Libdl", "Logging", "Markdown", "Printf", "REPL", "Random", "SHA", "Serialization", "TOML", "Tar", "UUIDs", "p7zip_jll"]
uuid = "44cfe95a-1eb2-52ea-b672-e2afdf69b78f"
version = "1.10.0"

[[deps.PkgVersion]]
deps = ["Pkg"]
git-tree-sha1 = "f9501cc0430a26bc3d156ae1b5b0c1b47af4d6da"
uuid = "eebad327-c553-4316-9ea0-9fa01ccd7688"
version = "0.3.3"

[[deps.PlotThemes]]
deps = ["PlotUtils", "Statistics"]
git-tree-sha1 = "1f03a2d339f42dca4a4da149c7e15e9b896ad899"
uuid = "ccf2f8ad-2431-5c83-bf29-c5338b663b6a"
version = "3.1.0"

[[deps.PlotUtils]]
deps = ["ColorSchemes", "Colors", "Dates", "PrecompileTools", "Printf", "Random", "Reexport", "Statistics"]
git-tree-sha1 = "7b1a9df27f072ac4c9c7cbe5efb198489258d1f5"
uuid = "995b91a9-d308-5afd-9ec6-746e21dbc043"
version = "1.4.1"

[[deps.Plots]]
deps = ["Base64", "Contour", "Dates", "Downloads", "FFMPEG", "FixedPointNumbers", "GR", "JLFzf", "JSON", "LaTeXStrings", "Latexify", "LinearAlgebra", "Measures", "NaNMath", "Pkg", "PlotThemes", "PlotUtils", "PrecompileTools", "Printf", "REPL", "Random", "RecipesBase", "RecipesPipeline", "Reexport", "RelocatableFolders", "Requires", "Scratch", "Showoff", "SparseArrays", "Statistics", "StatsBase", "UUIDs", "UnicodeFun", "UnitfulLatexify", "Unzip"]
git-tree-sha1 = "3c403c6590dd93b36752634115e20137e79ab4df"
uuid = "91a5bcdd-55d7-5caf-9e0b-520d859cae80"
version = "1.40.2"

    [deps.Plots.extensions]
    FileIOExt = "FileIO"
    GeometryBasicsExt = "GeometryBasics"
    IJuliaExt = "IJulia"
    ImageInTerminalExt = "ImageInTerminal"
    UnitfulExt = "Unitful"

    [deps.Plots.weakdeps]
    FileIO = "5789e2e9-d7fb-5bc7-8068-2c6fae9b9549"
    GeometryBasics = "5c1252a2-5f33-56bf-86c9-59e7332b4326"
    IJulia = "7073ff75-c697-5162-941a-fcdaad2a7d2a"
    ImageInTerminal = "d8c32880-2388-543b-8c61-d9f865259254"
    Unitful = "1986cc42-f94f-5a68-af5c-568840ba703d"

[[deps.PlutoHooks]]
deps = ["InteractiveUtils", "Markdown", "UUIDs"]
git-tree-sha1 = "072cdf20c9b0507fdd977d7d246d90030609674b"
uuid = "0ff47ea0-7a50-410d-8455-4348d5de0774"
version = "0.0.5"

[[deps.PlutoLinks]]
deps = ["FileWatching", "InteractiveUtils", "Markdown", "PlutoHooks", "Revise", "UUIDs"]
git-tree-sha1 = "8f5fa7056e6dcfb23ac5211de38e6c03f6367794"
uuid = "0ff47ea0-7a50-410d-8455-4348d5de0420"
version = "0.1.6"

[[deps.PlutoTeachingTools]]
deps = ["Downloads", "HypertextLiteral", "LaTeXStrings", "Latexify", "Markdown", "PlutoLinks", "PlutoUI", "Random"]
git-tree-sha1 = "89f57f710cc121a7f32473791af3d6beefc59051"
uuid = "661c6b06-c737-4d37-b85c-46df65de6f69"
version = "0.2.14"

[[deps.PlutoUI]]
deps = ["AbstractPlutoDingetjes", "Base64", "ColorTypes", "Dates", "FixedPointNumbers", "Hyperscript", "HypertextLiteral", "IOCapture", "InteractiveUtils", "JSON", "Logging", "MIMEs", "Markdown", "Random", "Reexport", "URIs", "UUIDs"]
git-tree-sha1 = "71a22244e352aa8c5f0f2adde4150f62368a3f2e"
uuid = "7f904dfe-b85e-4ff6-b463-dae2292396a8"
version = "0.7.58"

[[deps.PolyesterWeave]]
deps = ["BitTwiddlingConvenienceFunctions", "CPUSummary", "IfElse", "Static", "ThreadingUtilities"]
git-tree-sha1 = "240d7170f5ffdb285f9427b92333c3463bf65bf6"
uuid = "1d0040c9-8b98-4ee7-8388-3f51789ca0ad"
version = "0.2.1"

[[deps.Polynomials]]
deps = ["LinearAlgebra", "RecipesBase"]
git-tree-sha1 = "3aa2bb4982e575acd7583f01531f241af077b163"
uuid = "f27b6e38-b328-58d1-80ce-0feddd5e7a45"
version = "3.2.13"

    [deps.Polynomials.extensions]
    PolynomialsChainRulesCoreExt = "ChainRulesCore"
    PolynomialsMakieCoreExt = "MakieCore"
    PolynomialsMutableArithmeticsExt = "MutableArithmetics"

    [deps.Polynomials.weakdeps]
    ChainRulesCore = "d360d2e6-b24c-11e9-a2a3-2a2ae2dbcce4"
    MakieCore = "20f20a25-4f0e-4fdf-b5d1-57303727442b"
    MutableArithmetics = "d8a4904e-b15c-11e9-3269-09a3773c0cb0"

[[deps.PooledArrays]]
deps = ["DataAPI", "Future"]
git-tree-sha1 = "36d8b4b899628fb92c2749eb488d884a926614d3"
uuid = "2dfb63ee-cc39-5dd5-95bd-886bf059d720"
version = "1.4.3"

[[deps.PrecompileTools]]
deps = ["Preferences"]
git-tree-sha1 = "5aa36f7049a63a1528fe8f7c3f2113413ffd4e1f"
uuid = "aea7be01-6a6a-4083-8856-8a6e6704d82a"
version = "1.2.1"

[[deps.Preferences]]
deps = ["TOML"]
git-tree-sha1 = "9306f6085165d270f7e3db02af26a400d580f5c6"
uuid = "21216c6a-2e73-6563-6e65-726566657250"
version = "1.4.3"

[[deps.PrettyPrint]]
git-tree-sha1 = "632eb4abab3449ab30c5e1afaa874f0b98b586e4"
uuid = "8162dcfd-2161-5ef2-ae6c-7681170c5f98"
version = "0.2.0"

[[deps.PrettyTables]]
deps = ["Crayons", "LaTeXStrings", "Markdown", "PrecompileTools", "Printf", "Reexport", "StringManipulation", "Tables"]
git-tree-sha1 = "88b895d13d53b5577fd53379d913b9ab9ac82660"
uuid = "08abe8d2-0d0c-5749-adfa-8a2ac140af0d"
version = "2.3.1"

[[deps.Printf]]
deps = ["Unicode"]
uuid = "de0858da-6303-5e67-8744-51eddeeeb8d7"

[[deps.Profile]]
deps = ["Printf"]
uuid = "9abbd945-dff8-562f-b5e8-e1ebf5ef1b79"

[[deps.ProgressLogging]]
deps = ["Logging", "SHA", "UUIDs"]
git-tree-sha1 = "80d919dee55b9c50e8d9e2da5eeafff3fe58b539"
uuid = "33c8b6b6-d38a-422a-b730-caa89a2f386c"
version = "0.1.4"

[[deps.ProgressMeter]]
deps = ["Distributed", "Printf"]
git-tree-sha1 = "763a8ceb07833dd51bb9e3bbca372de32c0605ad"
uuid = "92933f4c-e287-5a05-a399-4b506db050ca"
version = "1.10.0"

[[deps.QOI]]
deps = ["ColorTypes", "FileIO", "FixedPointNumbers"]
git-tree-sha1 = "18e8f4d1426e965c7b532ddd260599e1510d26ce"
uuid = "4b34888f-f399-49d4-9bb3-47ed5cae4e65"
version = "1.0.0"

[[deps.Qt6Base_jll]]
deps = ["Artifacts", "CompilerSupportLibraries_jll", "Fontconfig_jll", "Glib_jll", "JLLWrappers", "Libdl", "Libglvnd_jll", "OpenSSL_jll", "Vulkan_Loader_jll", "Xorg_libSM_jll", "Xorg_libXext_jll", "Xorg_libXrender_jll", "Xorg_libxcb_jll", "Xorg_xcb_util_cursor_jll", "Xorg_xcb_util_image_jll", "Xorg_xcb_util_keysyms_jll", "Xorg_xcb_util_renderutil_jll", "Xorg_xcb_util_wm_jll", "Zlib_jll", "libinput_jll", "xkbcommon_jll"]
git-tree-sha1 = "37b7bb7aabf9a085e0044307e1717436117f2b3b"
uuid = "c0090381-4147-56d7-9ebc-da0b1113ec56"
version = "6.5.3+1"

[[deps.Quaternions]]
deps = ["LinearAlgebra", "Random", "RealDot"]
git-tree-sha1 = "994cc27cdacca10e68feb291673ec3a76aa2fae9"
uuid = "94ee1d12-ae83-5a48-8b1c-48b8ff168ae0"
version = "0.7.6"

[[deps.REPL]]
deps = ["InteractiveUtils", "Markdown", "Sockets", "Unicode"]
uuid = "3fa0cd96-eef1-5676-8a61-b3b8758bbffb"

[[deps.Random]]
deps = ["SHA"]
uuid = "9a3f8284-a2c9-5f02-9a11-845980a1fd5c"

[[deps.Random123]]
deps = ["Random", "RandomNumbers"]
git-tree-sha1 = "4743b43e5a9c4a2ede372de7061eed81795b12e7"
uuid = "74087812-796a-5b5d-8853-05524746bad3"
version = "1.7.0"

[[deps.RandomNumbers]]
deps = ["Random", "Requires"]
git-tree-sha1 = "043da614cc7e95c703498a491e2c21f58a2b8111"
uuid = "e6cf234a-135c-5ec9-84dd-332b85af5143"
version = "1.5.3"

[[deps.RangeArrays]]
git-tree-sha1 = "b9039e93773ddcfc828f12aadf7115b4b4d225f5"
uuid = "b3c3ace0-ae52-54e7-9d0b-2c1406fd6b9d"
version = "0.3.2"

[[deps.Ratios]]
deps = ["Requires"]
git-tree-sha1 = "1342a47bf3260ee108163042310d26f2be5ec90b"
uuid = "c84ed2f1-dad5-54f0-aa8e-dbefe2724439"
version = "0.4.5"
weakdeps = ["FixedPointNumbers"]

    [deps.Ratios.extensions]
    RatiosFixedPointNumbersExt = "FixedPointNumbers"

[[deps.RealDot]]
deps = ["LinearAlgebra"]
git-tree-sha1 = "9f0a1b71baaf7650f4fa8a1d168c7fb6ee41f0c9"
uuid = "c1ae055f-0cd5-4b69-90a6-9a35b1a98df9"
version = "0.1.0"

[[deps.RecipesBase]]
deps = ["PrecompileTools"]
git-tree-sha1 = "5c3d09cc4f31f5fc6af001c250bf1278733100ff"
uuid = "3cdcf5f2-1ef4-517c-9805-6587b60abb01"
version = "1.3.4"

[[deps.RecipesPipeline]]
deps = ["Dates", "NaNMath", "PlotUtils", "PrecompileTools", "RecipesBase"]
git-tree-sha1 = "45cf9fd0ca5839d06ef333c8201714e888486342"
uuid = "01d81517-befc-4cb6-b9ec-a95719d0359c"
version = "0.6.12"

[[deps.Reexport]]
git-tree-sha1 = "45e428421666073eab6f2da5c9d310d99bb12f9b"
uuid = "189a3867-3050-52da-a836-e630ba90ab69"
version = "1.2.2"

[[deps.Referenceables]]
deps = ["Adapt"]
git-tree-sha1 = "02d31ad62838181c1a3a5fd23a1ce5914a643601"
uuid = "42d2dcc6-99eb-4e98-b66c-637b7d73030e"
version = "0.1.3"

[[deps.RegionTrees]]
deps = ["IterTools", "LinearAlgebra", "StaticArrays"]
git-tree-sha1 = "4618ed0da7a251c7f92e869ae1a19c74a7d2a7f9"
uuid = "dee08c22-ab7f-5625-9660-a9af2021b33f"
version = "0.3.2"

[[deps.RelocatableFolders]]
deps = ["SHA", "Scratch"]
git-tree-sha1 = "ffdaf70d81cf6ff22c2b6e733c900c3321cab864"
uuid = "05181044-ff0b-4ac5-8273-598c1e38db00"
version = "1.0.1"

[[deps.RequiredInterfaces]]
deps = ["InteractiveUtils", "Logging", "Test"]
git-tree-sha1 = "e7eb973af4753abf5d866941268ec6ea2aec5556"
uuid = "97f35ef4-7bc5-4ec1-a41a-dcc69c7308c6"
version = "0.1.5"

[[deps.Requires]]
deps = ["UUIDs"]
git-tree-sha1 = "838a3a4188e2ded87a4f9f184b4b0d78a1e91cb7"
uuid = "ae029012-a4dd-5104-9daa-d747884805df"
version = "1.3.0"

[[deps.Revise]]
deps = ["CodeTracking", "Distributed", "FileWatching", "JuliaInterpreter", "LibGit2", "LoweredCodeUtils", "OrderedCollections", "Pkg", "REPL", "Requires", "UUIDs", "Unicode"]
git-tree-sha1 = "12aa2d7593df490c407a3bbd8b86b8b515017f3e"
uuid = "295af30f-e4ad-537b-8983-00126c2a3abe"
version = "3.5.14"

[[deps.Rmath]]
deps = ["Random", "Rmath_jll"]
git-tree-sha1 = "f65dcb5fa46aee0cf9ed6274ccbd597adc49aa7b"
uuid = "79098fc4-a85e-5d69-aa6a-4863f24498fa"
version = "0.7.1"

[[deps.Rmath_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "6ed52fdd3382cf21947b15e8870ac0ddbff736da"
uuid = "f50d1b31-88e8-58de-be2c-1cc44531875f"
version = "0.4.0+0"

[[deps.Rotations]]
deps = ["LinearAlgebra", "Quaternions", "Random", "StaticArrays"]
git-tree-sha1 = "2a0a5d8569f481ff8840e3b7c84bbf188db6a3fe"
uuid = "6038ab10-8711-5258-84ad-4b1120ba62dc"
version = "1.7.0"
weakdeps = ["RecipesBase"]

    [deps.Rotations.extensions]
    RotationsRecipesBaseExt = "RecipesBase"

[[deps.SHA]]
uuid = "ea8e919c-243c-51af-8825-aaa63cd721ce"
version = "0.7.0"

[[deps.SIMDTypes]]
git-tree-sha1 = "330289636fb8107c5f32088d2741e9fd7a061a5c"
uuid = "94e857df-77ce-4151-89e5-788b33177be4"
version = "0.1.0"

[[deps.SLEEFPirates]]
deps = ["IfElse", "Static", "VectorizationBase"]
git-tree-sha1 = "3aac6d68c5e57449f5b9b865c9ba50ac2970c4cf"
uuid = "476501e8-09a2-5ece-8869-fb82de89a1fa"
version = "0.6.42"

[[deps.Scratch]]
deps = ["Dates"]
git-tree-sha1 = "3bac05bc7e74a75fd9cba4295cde4045d9fe2386"
uuid = "6c6a2e73-6563-6170-7368-637461726353"
version = "1.2.1"

[[deps.SentinelArrays]]
deps = ["Dates", "Random"]
git-tree-sha1 = "0e7508ff27ba32f26cd459474ca2ede1bc10991f"
uuid = "91c51154-3ec4-41a3-a24f-3f23e20d615c"
version = "1.4.1"

[[deps.Serialization]]
uuid = "9e88b42a-f829-5b0c-bbe9-9e923198166b"

[[deps.Setfield]]
deps = ["ConstructionBase", "Future", "MacroTools", "StaticArraysCore"]
git-tree-sha1 = "e2cc6d8c88613c05e1defb55170bf5ff211fbeac"
uuid = "efcf1570-3423-57d1-acb7-fd33fddbac46"
version = "1.1.1"

[[deps.SharedArrays]]
deps = ["Distributed", "Mmap", "Random", "Serialization"]
uuid = "1a1011a3-84de-559e-8e89-a11a2f7dc383"

[[deps.ShowCases]]
git-tree-sha1 = "7f534ad62ab2bd48591bdeac81994ea8c445e4a5"
uuid = "605ecd9f-84a6-4c9e-81e2-4798472b76a3"
version = "0.1.0"

[[deps.Showoff]]
deps = ["Dates", "Grisu"]
git-tree-sha1 = "91eddf657aca81df9ae6ceb20b959ae5653ad1de"
uuid = "992d4aef-0814-514b-bc4d-f2e9a6c4116f"
version = "1.0.3"

[[deps.SimpleBufferStream]]
git-tree-sha1 = "874e8867b33a00e784c8a7e4b60afe9e037b74e1"
uuid = "777ac1f9-54b0-4bf8-805c-2214025038e7"
version = "1.1.0"

[[deps.SimpleTraits]]
deps = ["InteractiveUtils", "MacroTools"]
git-tree-sha1 = "5d7e3f4e11935503d3ecaf7186eac40602e7d231"
uuid = "699a6c99-e7fa-54fc-8d76-47d257e15c1d"
version = "0.9.4"

[[deps.SimpleUnPack]]
git-tree-sha1 = "58e6353e72cde29b90a69527e56df1b5c3d8c437"
uuid = "ce78b400-467f-4804-87d8-8f486da07d0a"
version = "1.1.0"

[[deps.SimpleWeightedGraphs]]
deps = ["Graphs", "LinearAlgebra", "Markdown", "SparseArrays"]
git-tree-sha1 = "4b33e0e081a825dbfaf314decf58fa47e53d6acb"
uuid = "47aef6b3-ad0c-573a-a1e2-d07658019622"
version = "1.4.0"

[[deps.Sixel]]
deps = ["Dates", "FileIO", "ImageCore", "IndirectArrays", "OffsetArrays", "REPL", "libsixel_jll"]
git-tree-sha1 = "2da10356e31327c7096832eb9cd86307a50b1eb6"
uuid = "45858cf5-a6b0-47a3-bbea-62219f50df47"
version = "0.1.3"

[[deps.Sockets]]
uuid = "6462fe0b-24de-5631-8697-dd941f90decc"

[[deps.SortingAlgorithms]]
deps = ["DataStructures"]
git-tree-sha1 = "66e0a8e672a0bdfca2c3f5937efb8538b9ddc085"
uuid = "a2af1166-a08f-5f64-846c-94a0d3cef48c"
version = "1.2.1"

[[deps.SparseArrays]]
deps = ["Libdl", "LinearAlgebra", "Random", "Serialization", "SuiteSparse_jll"]
uuid = "2f01184e-e22b-5df5-ae63-d93ebab69eaf"
version = "1.10.0"

[[deps.SparseInverseSubset]]
deps = ["LinearAlgebra", "SparseArrays", "SuiteSparse"]
git-tree-sha1 = "52962839426b75b3021296f7df242e40ecfc0852"
uuid = "dc90abb0-5640-4711-901d-7e5b23a2fada"
version = "0.1.2"

[[deps.SpecialFunctions]]
deps = ["IrrationalConstants", "LogExpFunctions", "OpenLibm_jll", "OpenSpecFun_jll"]
git-tree-sha1 = "e2cfc4012a19088254b3950b85c3c1d8882d864d"
uuid = "276daf66-3868-5448-9aa4-cd146d93841b"
version = "2.3.1"
weakdeps = ["ChainRulesCore"]

    [deps.SpecialFunctions.extensions]
    SpecialFunctionsChainRulesCoreExt = "ChainRulesCore"

[[deps.SplittablesBase]]
deps = ["Setfield", "Test"]
git-tree-sha1 = "e08a62abc517eb79667d0a29dc08a3b589516bb5"
uuid = "171d559e-b47b-412a-8079-5efa626c420e"
version = "0.1.15"

[[deps.StackViews]]
deps = ["OffsetArrays"]
git-tree-sha1 = "46e589465204cd0c08b4bd97385e4fa79a0c770c"
uuid = "cae243ae-269e-4f55-b966-ac2d0dc13c15"
version = "0.1.1"

[[deps.Static]]
deps = ["IfElse"]
git-tree-sha1 = "d2fdac9ff3906e27f7a618d47b676941baa6c80c"
uuid = "aedffcd0-7271-4cad-89d0-dc628f76c6d3"
version = "0.8.10"

[[deps.StaticArrayInterface]]
deps = ["ArrayInterface", "Compat", "IfElse", "LinearAlgebra", "PrecompileTools", "Requires", "SparseArrays", "Static", "SuiteSparse"]
git-tree-sha1 = "5d66818a39bb04bf328e92bc933ec5b4ee88e436"
uuid = "0d7ed370-da01-4f52-bd93-41d350b8b718"
version = "1.5.0"
weakdeps = ["OffsetArrays", "StaticArrays"]

    [deps.StaticArrayInterface.extensions]
    StaticArrayInterfaceOffsetArraysExt = "OffsetArrays"
    StaticArrayInterfaceStaticArraysExt = "StaticArrays"

[[deps.StaticArrays]]
deps = ["LinearAlgebra", "PrecompileTools", "Random", "StaticArraysCore"]
git-tree-sha1 = "bf074c045d3d5ffd956fa0a461da38a44685d6b2"
uuid = "90137ffa-7385-5640-81b9-e52037218182"
version = "1.9.3"
weakdeps = ["ChainRulesCore", "Statistics"]

    [deps.StaticArrays.extensions]
    StaticArraysChainRulesCoreExt = "ChainRulesCore"
    StaticArraysStatisticsExt = "Statistics"

[[deps.StaticArraysCore]]
git-tree-sha1 = "36b3d696ce6366023a0ea192b4cd442268995a0d"
uuid = "1e83bf80-4336-4d27-bf5d-d5a4f845583c"
version = "1.4.2"

[[deps.Statistics]]
deps = ["LinearAlgebra", "SparseArrays"]
uuid = "10745b16-79ce-11e8-11f9-7d13ad32a3b2"
version = "1.10.0"

[[deps.StatsAPI]]
deps = ["LinearAlgebra"]
git-tree-sha1 = "1ff449ad350c9c4cbc756624d6f8a8c3ef56d3ed"
uuid = "82ae8749-77ed-4fe6-ae5f-f523153014b0"
version = "1.7.0"

[[deps.StatsBase]]
deps = ["DataAPI", "DataStructures", "LinearAlgebra", "LogExpFunctions", "Missings", "Printf", "Random", "SortingAlgorithms", "SparseArrays", "Statistics", "StatsAPI"]
git-tree-sha1 = "1d77abd07f617c4868c33d4f5b9e1dbb2643c9cf"
uuid = "2913bbd2-ae8a-5f71-8c99-4fb6c76f3a91"
version = "0.34.2"

[[deps.StatsFuns]]
deps = ["HypergeometricFunctions", "IrrationalConstants", "LogExpFunctions", "Reexport", "Rmath", "SpecialFunctions"]
git-tree-sha1 = "cef0472124fab0695b58ca35a77c6fb942fdab8a"
uuid = "4c63d2b9-4356-54db-8cca-17b64c39e42c"
version = "1.3.1"
weakdeps = ["ChainRulesCore", "InverseFunctions"]

    [deps.StatsFuns.extensions]
    StatsFunsChainRulesCoreExt = "ChainRulesCore"
    StatsFunsInverseFunctionsExt = "InverseFunctions"

[[deps.StringManipulation]]
deps = ["PrecompileTools"]
git-tree-sha1 = "a04cabe79c5f01f4d723cc6704070ada0b9d46d5"
uuid = "892a3eda-7b42-436c-8928-eab12a02cf0e"
version = "0.3.4"

[[deps.StructArrays]]
deps = ["ConstructionBase", "DataAPI", "Tables"]
git-tree-sha1 = "f4dc295e983502292c4c3f951dbb4e985e35b3be"
uuid = "09ab397b-f2b6-538f-b94a-2f83cf4a842a"
version = "0.6.18"
weakdeps = ["Adapt", "GPUArraysCore", "SparseArrays", "StaticArrays"]

    [deps.StructArrays.extensions]
    StructArraysAdaptExt = "Adapt"
    StructArraysGPUArraysCoreExt = "GPUArraysCore"
    StructArraysSparseArraysExt = "SparseArrays"
    StructArraysStaticArraysExt = "StaticArrays"

[[deps.SuiteSparse]]
deps = ["Libdl", "LinearAlgebra", "Serialization", "SparseArrays"]
uuid = "4607b0f0-06f3-5cda-b6b1-a6196a1729e9"

[[deps.SuiteSparse_jll]]
deps = ["Artifacts", "Libdl", "libblastrampoline_jll"]
uuid = "bea87d4a-7f5b-5778-9afe-8cc45184846c"
version = "7.2.1+1"

[[deps.TOML]]
deps = ["Dates"]
uuid = "fa267f1f-6049-4f14-aa54-33bafae1ed76"
version = "1.0.3"

[[deps.TableTraits]]
deps = ["IteratorInterfaceExtensions"]
git-tree-sha1 = "c06b2f539df1c6efa794486abfb6ed2022561a39"
uuid = "3783bdb8-4a98-5b6b-af9a-565f29a5fe9c"
version = "1.0.1"

[[deps.Tables]]
deps = ["DataAPI", "DataValueInterfaces", "IteratorInterfaceExtensions", "LinearAlgebra", "OrderedCollections", "TableTraits"]
git-tree-sha1 = "cb76cf677714c095e535e3501ac7954732aeea2d"
uuid = "bd369af6-aec1-5ad0-b16a-f7cc5008161c"
version = "1.11.1"

[[deps.Tar]]
deps = ["ArgTools", "SHA"]
uuid = "a4e569a6-e804-4fa4-b0f3-eef7a1d5b13e"
version = "1.10.0"

[[deps.TensorCore]]
deps = ["LinearAlgebra"]
git-tree-sha1 = "1feb45f88d133a655e001435632f019a9a1bcdb6"
uuid = "62fd8b95-f654-4bbd-a8a5-9c27f68ccd50"
version = "0.1.1"

[[deps.Test]]
deps = ["InteractiveUtils", "Logging", "Random", "Serialization"]
uuid = "8dfed614-e22c-5e08-85e1-65c5234f0b40"

[[deps.ThreadingUtilities]]
deps = ["ManualMemory"]
git-tree-sha1 = "eda08f7e9818eb53661b3deb74e3159460dfbc27"
uuid = "8290d209-cae3-49c0-8002-c8c24d57dab5"
version = "0.5.2"

[[deps.ThreadsX]]
deps = ["Accessors", "ArgCheck", "BangBang", "ConstructionBase", "InitialValues", "MicroCollections", "Referenceables", "SplittablesBase", "Transducers"]
git-tree-sha1 = "70bd8244f4834d46c3d68bd09e7792d8f571ef04"
uuid = "ac1d9e8a-700a-412c-b207-f0111f4b6c0d"
version = "0.1.12"

[[deps.TiffImages]]
deps = ["ColorTypes", "DataStructures", "DocStringExtensions", "FileIO", "FixedPointNumbers", "IndirectArrays", "Inflate", "Mmap", "OffsetArrays", "PkgVersion", "ProgressMeter", "UUIDs"]
git-tree-sha1 = "34cc045dd0aaa59b8bbe86c644679bc57f1d5bd0"
uuid = "731e570b-9d59-4bfa-96dc-6df516fadf69"
version = "0.6.8"

[[deps.TiledIteration]]
deps = ["OffsetArrays", "StaticArrayInterface"]
git-tree-sha1 = "1176cc31e867217b06928e2f140c90bd1bc88283"
uuid = "06e1c1a7-607b-532d-9fad-de7d9aa2abac"
version = "0.5.0"

[[deps.TimerOutputs]]
deps = ["ExprTools", "Printf"]
git-tree-sha1 = "f548a9e9c490030e545f72074a41edfd0e5bcdd7"
uuid = "a759f4b9-e2f1-59dc-863e-4aeb61b1ea8f"
version = "0.5.23"

[[deps.TranscodingStreams]]
git-tree-sha1 = "3caa21522e7efac1ba21834a03734c57b4611c7e"
uuid = "3bb67fe8-82b1-5028-8e26-92a6c54297fa"
version = "0.10.4"
weakdeps = ["Random", "Test"]

    [deps.TranscodingStreams.extensions]
    TestExt = ["Test", "Random"]

[[deps.Transducers]]
deps = ["Adapt", "ArgCheck", "BangBang", "Baselet", "CompositionsBase", "ConstructionBase", "DefineSingletons", "Distributed", "InitialValues", "Logging", "Markdown", "MicroCollections", "Requires", "Setfield", "SplittablesBase", "Tables"]
git-tree-sha1 = "3064e780dbb8a9296ebb3af8f440f787bb5332af"
uuid = "28d57a85-8fef-5791-bfe6-a80928e7c999"
version = "0.4.80"

    [deps.Transducers.extensions]
    TransducersBlockArraysExt = "BlockArrays"
    TransducersDataFramesExt = "DataFrames"
    TransducersLazyArraysExt = "LazyArrays"
    TransducersOnlineStatsBaseExt = "OnlineStatsBase"
    TransducersReferenceablesExt = "Referenceables"

    [deps.Transducers.weakdeps]
    BlockArrays = "8e7c35d0-a365-5155-bbbb-fb81a777f24e"
    DataFrames = "a93c6f00-e57d-5684-b7b6-d8193f3e46c0"
    LazyArrays = "5078a376-72f3-5289-bfd5-ec5146d43c02"
    OnlineStatsBase = "925886fa-5bf2-5e8e-b522-a9147a512338"
    Referenceables = "42d2dcc6-99eb-4e98-b66c-637b7d73030e"

[[deps.Tricks]]
git-tree-sha1 = "eae1bb484cd63b36999ee58be2de6c178105112f"
uuid = "410a4b4d-49e4-4fbc-ab6d-cb71b17b3775"
version = "0.1.8"

[[deps.URIs]]
git-tree-sha1 = "67db6cc7b3821e19ebe75791a9dd19c9b1188f2b"
uuid = "5c2747f8-b7ea-4ff2-ba2e-563bfd36b1d4"
version = "1.5.1"

[[deps.UUIDs]]
deps = ["Random", "SHA"]
uuid = "cf7118a7-6976-5b1a-9a39-7adc72f591a4"

[[deps.UnPack]]
git-tree-sha1 = "387c1f73762231e86e0c9c5443ce3b4a0a9a0c2b"
uuid = "3a884ed6-31ef-47d7-9d2a-63182c4928ed"
version = "1.0.2"

[[deps.Unicode]]
uuid = "4ec0a83e-493e-50e2-b9ac-8f72acf5a8f5"

[[deps.UnicodeFun]]
deps = ["REPL"]
git-tree-sha1 = "53915e50200959667e78a92a418594b428dffddf"
uuid = "1cfade01-22cf-5700-b092-accc4b62d6e1"
version = "0.4.1"

[[deps.UnicodePlots]]
deps = ["ColorSchemes", "ColorTypes", "Contour", "Crayons", "Dates", "LinearAlgebra", "MarchingCubes", "NaNMath", "PrecompileTools", "Printf", "Requires", "SparseArrays", "StaticArrays", "StatsBase"]
git-tree-sha1 = "30646456e889c18fb3c23e58b2fc5da23644f752"
uuid = "b8865327-cd53-5732-bb35-84acbb429228"
version = "3.6.4"

    [deps.UnicodePlots.extensions]
    FreeTypeExt = ["FileIO", "FreeType"]
    ImageInTerminalExt = "ImageInTerminal"
    IntervalSetsExt = "IntervalSets"
    TermExt = "Term"
    UnitfulExt = "Unitful"

    [deps.UnicodePlots.weakdeps]
    FileIO = "5789e2e9-d7fb-5bc7-8068-2c6fae9b9549"
    FreeType = "b38be410-82b0-50bf-ab77-7b57e271db43"
    ImageInTerminal = "d8c32880-2388-543b-8c61-d9f865259254"
    IntervalSets = "8197267c-284f-5f27-9208-e0e47529a953"
    Term = "22787eb5-b846-44ae-b979-8e399b8463ab"
    Unitful = "1986cc42-f94f-5a68-af5c-568840ba703d"

[[deps.Unitful]]
deps = ["Dates", "LinearAlgebra", "Random"]
git-tree-sha1 = "3c793be6df9dd77a0cf49d80984ef9ff996948fa"
uuid = "1986cc42-f94f-5a68-af5c-568840ba703d"
version = "1.19.0"
weakdeps = ["ConstructionBase", "InverseFunctions"]

    [deps.Unitful.extensions]
    ConstructionBaseUnitfulExt = "ConstructionBase"
    InverseFunctionsUnitfulExt = "InverseFunctions"

[[deps.UnitfulLatexify]]
deps = ["LaTeXStrings", "Latexify", "Unitful"]
git-tree-sha1 = "e2d817cc500e960fdbafcf988ac8436ba3208bfd"
uuid = "45397f5d-5981-4c77-b2b3-fc36d6e9b728"
version = "1.6.3"

[[deps.UnsafeAtomics]]
git-tree-sha1 = "6331ac3440856ea1988316b46045303bef658278"
uuid = "013be700-e6cd-48c3-b4a1-df204f14c38f"
version = "0.2.1"

[[deps.UnsafeAtomicsLLVM]]
deps = ["LLVM", "UnsafeAtomics"]
git-tree-sha1 = "323e3d0acf5e78a56dfae7bd8928c989b4f3083e"
uuid = "d80eeb9a-aca5-4d75-85e5-170c8b632249"
version = "0.1.3"

[[deps.Unzip]]
git-tree-sha1 = "ca0969166a028236229f63514992fc073799bb78"
uuid = "41fe7b60-77ed-43a1-b4f0-825fd5a5650d"
version = "0.2.0"

[[deps.VectorizationBase]]
deps = ["ArrayInterface", "CPUSummary", "HostCPUFeatures", "IfElse", "LayoutPointers", "Libdl", "LinearAlgebra", "SIMDTypes", "Static", "StaticArrayInterface"]
git-tree-sha1 = "7209df901e6ed7489fe9b7aa3e46fb788e15db85"
uuid = "3d5dd08c-fd9d-11e8-17fa-ed2836048c2f"
version = "0.21.65"

[[deps.Vulkan_Loader_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Wayland_jll", "Xorg_libX11_jll", "Xorg_libXrandr_jll", "xkbcommon_jll"]
git-tree-sha1 = "2f0486047a07670caad3a81a075d2e518acc5c59"
uuid = "a44049a8-05dd-5a78-86c9-5fde0876e88c"
version = "1.3.243+0"

[[deps.Wayland_jll]]
deps = ["Artifacts", "EpollShim_jll", "Expat_jll", "JLLWrappers", "Libdl", "Libffi_jll", "Pkg", "XML2_jll"]
git-tree-sha1 = "7558e29847e99bc3f04d6569e82d0f5c54460703"
uuid = "a2964d1f-97da-50d4-b82a-358c7fce9d89"
version = "1.21.0+1"

[[deps.Wayland_protocols_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "93f43ab61b16ddfb2fd3bb13b3ce241cafb0e6c9"
uuid = "2381bf8a-dfd0-557d-9999-79630e7b1b91"
version = "1.31.0+0"

[[deps.WeakRefStrings]]
deps = ["DataAPI", "InlineStrings", "Parsers"]
git-tree-sha1 = "b1be2855ed9ed8eac54e5caff2afcdb442d52c23"
uuid = "ea10d353-3f73-51f8-a26c-33c1cb351aa5"
version = "1.4.2"

[[deps.WoodburyMatrices]]
deps = ["LinearAlgebra", "SparseArrays"]
git-tree-sha1 = "c1a7aa6219628fcd757dede0ca95e245c5cd9511"
uuid = "efce3f68-66dc-5838-9240-27a6d6f5f9b6"
version = "1.0.0"

[[deps.WorkerUtilities]]
git-tree-sha1 = "cd1659ba0d57b71a464a29e64dbc67cfe83d54e7"
uuid = "76eceee3-57b5-4d4a-8e66-0e911cebbf60"
version = "1.6.1"

[[deps.XML2_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Libiconv_jll", "Zlib_jll"]
git-tree-sha1 = "07e470dabc5a6a4254ffebc29a1b3fc01464e105"
uuid = "02c8fc9c-b97f-50b9-bbe4-9be30ff0a78a"
version = "2.12.5+0"

[[deps.XSLT_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Libgcrypt_jll", "Libgpg_error_jll", "Libiconv_jll", "Pkg", "XML2_jll", "Zlib_jll"]
git-tree-sha1 = "91844873c4085240b95e795f692c4cec4d805f8a"
uuid = "aed1982a-8fda-507f-9586-7b0439959a61"
version = "1.1.34+0"

[[deps.XZ_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl"]
git-tree-sha1 = "31c421e5516a6248dfb22c194519e37effbf1f30"
uuid = "ffd25f8a-64ca-5728-b0f7-c24cf3aae800"
version = "5.6.1+0"

[[deps.Xorg_libICE_jll]]
deps = ["Libdl", "Pkg"]
git-tree-sha1 = "e5becd4411063bdcac16be8b66fc2f9f6f1e8fe5"
uuid = "f67eecfb-183a-506d-b269-f58e52b52d7c"
version = "1.0.10+1"

[[deps.Xorg_libSM_jll]]
deps = ["Libdl", "Pkg", "Xorg_libICE_jll"]
git-tree-sha1 = "4a9d9e4c180e1e8119b5ffc224a7b59d3a7f7e18"
uuid = "c834827a-8449-5923-a945-d239c165b7dd"
version = "1.2.3+0"

[[deps.Xorg_libX11_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Xorg_libxcb_jll", "Xorg_xtrans_jll"]
git-tree-sha1 = "afead5aba5aa507ad5a3bf01f58f82c8d1403495"
uuid = "4f6342f7-b3d2-589e-9d20-edeb45f2b2bc"
version = "1.8.6+0"

[[deps.Xorg_libXau_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl"]
git-tree-sha1 = "6035850dcc70518ca32f012e46015b9beeda49d8"
uuid = "0c0b7dd1-d40b-584c-a123-a41640f87eec"
version = "1.0.11+0"

[[deps.Xorg_libXcursor_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg", "Xorg_libXfixes_jll", "Xorg_libXrender_jll"]
git-tree-sha1 = "12e0eb3bc634fa2080c1c37fccf56f7c22989afd"
uuid = "935fb764-8cf2-53bf-bb30-45bb1f8bf724"
version = "1.2.0+4"

[[deps.Xorg_libXdmcp_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl"]
git-tree-sha1 = "34d526d318358a859d7de23da945578e8e8727b7"
uuid = "a3789734-cfe1-5b06-b2d0-1dd0d9d62d05"
version = "1.1.4+0"

[[deps.Xorg_libXext_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg", "Xorg_libX11_jll"]
git-tree-sha1 = "b7c0aa8c376b31e4852b360222848637f481f8c3"
uuid = "1082639a-0dae-5f34-9b06-72781eeb8cb3"
version = "1.3.4+4"

[[deps.Xorg_libXfixes_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg", "Xorg_libX11_jll"]
git-tree-sha1 = "0e0dc7431e7a0587559f9294aeec269471c991a4"
uuid = "d091e8ba-531a-589c-9de9-94069b037ed8"
version = "5.0.3+4"

[[deps.Xorg_libXi_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg", "Xorg_libXext_jll", "Xorg_libXfixes_jll"]
git-tree-sha1 = "89b52bc2160aadc84d707093930ef0bffa641246"
uuid = "a51aa0fd-4e3c-5386-b890-e753decda492"
version = "1.7.10+4"

[[deps.Xorg_libXinerama_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg", "Xorg_libXext_jll"]
git-tree-sha1 = "26be8b1c342929259317d8b9f7b53bf2bb73b123"
uuid = "d1454406-59df-5ea1-beac-c340f2130bc3"
version = "1.1.4+4"

[[deps.Xorg_libXrandr_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg", "Xorg_libXext_jll", "Xorg_libXrender_jll"]
git-tree-sha1 = "34cea83cb726fb58f325887bf0612c6b3fb17631"
uuid = "ec84b674-ba8e-5d96-8ba1-2a689ba10484"
version = "1.5.2+4"

[[deps.Xorg_libXrender_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg", "Xorg_libX11_jll"]
git-tree-sha1 = "19560f30fd49f4d4efbe7002a1037f8c43d43b96"
uuid = "ea2f1a96-1ddc-540d-b46f-429655e07cfa"
version = "0.9.10+4"

[[deps.Xorg_libpthread_stubs_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl"]
git-tree-sha1 = "8fdda4c692503d44d04a0603d9ac0982054635f9"
uuid = "14d82f49-176c-5ed1-bb49-ad3f5cbd8c74"
version = "0.1.1+0"

[[deps.Xorg_libxcb_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "XSLT_jll", "Xorg_libXau_jll", "Xorg_libXdmcp_jll", "Xorg_libpthread_stubs_jll"]
git-tree-sha1 = "b4bfde5d5b652e22b9c790ad00af08b6d042b97d"
uuid = "c7cfdc94-dc32-55de-ac96-5a1b8d977c5b"
version = "1.15.0+0"

[[deps.Xorg_libxkbfile_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Xorg_libX11_jll"]
git-tree-sha1 = "730eeca102434283c50ccf7d1ecdadf521a765a4"
uuid = "cc61e674-0454-545c-8b26-ed2c68acab7a"
version = "1.1.2+0"

[[deps.Xorg_xcb_util_cursor_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Xorg_xcb_util_image_jll", "Xorg_xcb_util_jll", "Xorg_xcb_util_renderutil_jll"]
git-tree-sha1 = "04341cb870f29dcd5e39055f895c39d016e18ccd"
uuid = "e920d4aa-a673-5f3a-b3d7-f755a4d47c43"
version = "0.1.4+0"

[[deps.Xorg_xcb_util_image_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg", "Xorg_xcb_util_jll"]
git-tree-sha1 = "0fab0a40349ba1cba2c1da699243396ff8e94b97"
uuid = "12413925-8142-5f55-bb0e-6d7ca50bb09b"
version = "0.4.0+1"

[[deps.Xorg_xcb_util_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg", "Xorg_libxcb_jll"]
git-tree-sha1 = "e7fd7b2881fa2eaa72717420894d3938177862d1"
uuid = "2def613f-5ad1-5310-b15b-b15d46f528f5"
version = "0.4.0+1"

[[deps.Xorg_xcb_util_keysyms_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg", "Xorg_xcb_util_jll"]
git-tree-sha1 = "d1151e2c45a544f32441a567d1690e701ec89b00"
uuid = "975044d2-76e6-5fbe-bf08-97ce7c6574c7"
version = "0.4.0+1"

[[deps.Xorg_xcb_util_renderutil_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg", "Xorg_xcb_util_jll"]
git-tree-sha1 = "dfd7a8f38d4613b6a575253b3174dd991ca6183e"
uuid = "0d47668e-0667-5a69-a72c-f761630bfb7e"
version = "0.3.9+1"

[[deps.Xorg_xcb_util_wm_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg", "Xorg_xcb_util_jll"]
git-tree-sha1 = "e78d10aab01a4a154142c5006ed44fd9e8e31b67"
uuid = "c22f9ab0-d5fe-5066-847c-f4bb1cd4e361"
version = "0.4.1+1"

[[deps.Xorg_xkbcomp_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Xorg_libxkbfile_jll"]
git-tree-sha1 = "330f955bc41bb8f5270a369c473fc4a5a4e4d3cb"
uuid = "35661453-b289-5fab-8a00-3d9160c6a3a4"
version = "1.4.6+0"

[[deps.Xorg_xkeyboard_config_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Xorg_xkbcomp_jll"]
git-tree-sha1 = "691634e5453ad362044e2ad653e79f3ee3bb98c3"
uuid = "33bec58e-1273-512f-9401-5d533626f822"
version = "2.39.0+0"

[[deps.Xorg_xtrans_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl"]
git-tree-sha1 = "e92a1a012a10506618f10b7047e478403a046c77"
uuid = "c5fb5394-a638-5e4d-96e5-b29de1b5cf10"
version = "1.5.0+0"

[[deps.ZipFile]]
deps = ["Libdl", "Printf", "Zlib_jll"]
git-tree-sha1 = "f492b7fe1698e623024e873244f10d89c95c340a"
uuid = "a5390f91-8eb1-5f08-bee0-b1d1ffed6cea"
version = "0.10.1"

[[deps.Zlib_jll]]
deps = ["Libdl"]
uuid = "83775a58-1f1d-513f-b197-d71354ab007a"
version = "1.2.13+1"

[[deps.Zstd_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl"]
git-tree-sha1 = "49ce682769cd5de6c72dcf1b94ed7790cd08974c"
uuid = "3161d3a3-bdf6-5164-811a-617609db77b4"
version = "1.5.5+0"

[[deps.Zygote]]
deps = ["AbstractFFTs", "ChainRules", "ChainRulesCore", "DiffRules", "Distributed", "FillArrays", "ForwardDiff", "GPUArrays", "GPUArraysCore", "IRTools", "InteractiveUtils", "LinearAlgebra", "LogExpFunctions", "MacroTools", "NaNMath", "PrecompileTools", "Random", "Requires", "SparseArrays", "SpecialFunctions", "Statistics", "ZygoteRules"]
git-tree-sha1 = "4ddb4470e47b0094c93055a3bcae799165cc68f1"
uuid = "e88e6eb3-aa80-5325-afca-941959d7151f"
version = "0.6.69"

    [deps.Zygote.extensions]
    ZygoteColorsExt = "Colors"
    ZygoteDistancesExt = "Distances"
    ZygoteTrackerExt = "Tracker"

    [deps.Zygote.weakdeps]
    Colors = "5ae59095-9a9b-59fe-a467-6f913c188581"
    Distances = "b4f34e82-e78d-54a5-968a-f98e89d6e8f7"
    Tracker = "9f7883ad-71c0-57eb-9f7f-b5c9e6d3789c"

[[deps.ZygoteRules]]
deps = ["ChainRulesCore", "MacroTools"]
git-tree-sha1 = "27798139afc0a2afa7b1824c206d5e87ea587a00"
uuid = "700de1a5-db45-46bc-99cf-38207098b444"
version = "0.2.5"

[[deps.cuDNN]]
deps = ["CEnum", "CUDA", "CUDA_Runtime_Discovery", "CUDNN_jll"]
git-tree-sha1 = "d433ec29756895512190cac9c96666d879f07b92"
uuid = "02a925ec-e4fe-4b08-9a7e-0d78e3d38ccd"
version = "1.3.0"

[[deps.eudev_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg", "gperf_jll"]
git-tree-sha1 = "431b678a28ebb559d224c0b6b6d01afce87c51ba"
uuid = "35ca27e7-8b34-5b7f-bca9-bdc33f59eb06"
version = "3.2.9+0"

[[deps.fzf_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl"]
git-tree-sha1 = "a68c9655fbe6dfcab3d972808f1aafec151ce3f8"
uuid = "214eeab7-80f7-51ab-84ad-2988db7cef09"
version = "0.43.0+0"

[[deps.gperf_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "3516a5630f741c9eecb3720b1ec9d8edc3ecc033"
uuid = "1a1c6b14-54f6-533d-8383-74cd7377aa70"
version = "3.1.1+0"

[[deps.libaom_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "3a2ea60308f0996d26f1e5354e10c24e9ef905d4"
uuid = "a4ae2306-e953-59d6-aa16-d00cac43593b"
version = "3.4.0+0"

[[deps.libass_jll]]
deps = ["Artifacts", "Bzip2_jll", "FreeType2_jll", "FriBidi_jll", "HarfBuzz_jll", "JLLWrappers", "Libdl", "Pkg", "Zlib_jll"]
git-tree-sha1 = "5982a94fcba20f02f42ace44b9894ee2b140fe47"
uuid = "0ac62f75-1d6f-5e53-bd7c-93b484bb37c0"
version = "0.15.1+0"

[[deps.libblastrampoline_jll]]
deps = ["Artifacts", "Libdl"]
uuid = "8e850b90-86db-534c-a0d3-1478176c7d93"
version = "5.8.0+1"

[[deps.libevdev_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "141fe65dc3efabb0b1d5ba74e91f6ad26f84cc22"
uuid = "2db6ffa8-e38f-5e21-84af-90c45d0032cc"
version = "1.11.0+0"

[[deps.libfdk_aac_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "daacc84a041563f965be61859a36e17c4e4fcd55"
uuid = "f638f0a6-7fb0-5443-88ba-1cc74229b280"
version = "2.0.2+0"

[[deps.libinput_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg", "eudev_jll", "libevdev_jll", "mtdev_jll"]
git-tree-sha1 = "ad50e5b90f222cfe78aa3d5183a20a12de1322ce"
uuid = "36db933b-70db-51c0-b978-0f229ee0e533"
version = "1.18.0+0"

[[deps.libpng_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Zlib_jll"]
git-tree-sha1 = "d7015d2e18a5fd9a4f47de711837e980519781a4"
uuid = "b53b4c65-9356-5827-b1ea-8c7a1a84506f"
version = "1.6.43+1"

[[deps.libsixel_jll]]
deps = ["Artifacts", "JLLWrappers", "JpegTurbo_jll", "Libdl", "Pkg", "libpng_jll"]
git-tree-sha1 = "d4f63314c8aa1e48cd22aa0c17ed76cd1ae48c3c"
uuid = "075b6546-f08a-558a-be8f-8157d0f608a5"
version = "1.10.3+0"

[[deps.libvorbis_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Ogg_jll", "Pkg"]
git-tree-sha1 = "b910cb81ef3fe6e78bf6acee440bda86fd6ae00c"
uuid = "f27f6e37-5d2b-51aa-960f-b287f2bc3b7a"
version = "1.3.7+1"

[[deps.mtdev_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "814e154bdb7be91d78b6802843f76b6ece642f11"
uuid = "009596ad-96f7-51b1-9f1b-5ce2d5e8a71e"
version = "1.1.6+0"

[[deps.nghttp2_jll]]
deps = ["Artifacts", "Libdl"]
uuid = "8e850ede-7688-5339-a07c-302acd2aaf8d"
version = "1.52.0+1"

[[deps.p7zip_jll]]
deps = ["Artifacts", "Libdl"]
uuid = "3f19e933-33d8-53b3-aaab-bd5110c3b7a0"
version = "17.4.0+2"

[[deps.x264_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "4fea590b89e6ec504593146bf8b988b2c00922b2"
uuid = "1270edf5-f2f9-52d2-97e9-ab00b5d0237a"
version = "2021.5.5+0"

[[deps.x265_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg"]
git-tree-sha1 = "ee567a171cce03570d77ad3a43e90218e38937a9"
uuid = "dfaa095f-4041-5dcd-9319-2fabd8486b76"
version = "3.5.0+0"

[[deps.xkbcommon_jll]]
deps = ["Artifacts", "JLLWrappers", "Libdl", "Pkg", "Wayland_jll", "Wayland_protocols_jll", "Xorg_libxcb_jll", "Xorg_xkeyboard_config_jll"]
git-tree-sha1 = "9c304562909ab2bab0262639bd4f444d7bc2be37"
uuid = "d8fb68d0-12a3-5cfd-a85a-d49703b185fd"
version = "1.4.1+1"
"""

# ╔═╡ Cell order:
# ╟─4bedc602-dfb0-11ee-2bd4-6d7b3adab5eb
# ╟─e566670d-80a7-46a2-868f-c1f192ae8054
# ╠═6fbdd5ca-336e-453e-a072-c022bf1b215f
# ╟─f6e42473-a82b-4218-89f6-d65c7e699741
# ╟─44e70c56-5a44-42ca-ad49-3db02aabaafb
# ╟─31e80172-283f-4dd5-9185-ffff23c99b29
# ╟─025978d4-4f08-4ae5-9409-2157e6cb8d18
# ╟─a85f0bbf-4b22-45ea-b323-cd8a349aa600
# ╟─7da75f97-621d-4daa-bf2c-9302c176ab38
# ╟─040e9923-db8f-42c2-b797-74265d4f5b69
# ╟─3f405394-e637-49d1-98f8-6ecfc7c778a7
# ╟─e9774758-f1c1-4a5c-821f-34fb78503b79
# ╟─8a94c7e1-b026-4030-9539-647e954f7d1f
# ╟─d1c0d37e-303a-424d-bb8b-e7c9b790b08c
# ╟─10436cb9-1b60-48fb-85fa-f3399acf93da
# ╟─05d86a93-229d-45f7-aea7-b7fb365ff03e
# ╟─f0ebe7af-ff03-4096-908c-f8cdc2c4bf65
# ╟─62857553-65f7-4b6e-97b3-efca5f6f4f8b
# ╟─eff6c854-fb67-4dec-821c-3f8ee56563ac
# ╟─9f67cb84-3572-48f1-890a-34c8eeae75bd
# ╟─26b1995b-606b-441d-8707-b0212fa504e9
# ╟─8f5ff133-120f-44c5-b522-adbd01072af0
# ╟─7e6b8425-76db-4d0f-9f3e-2edb05a3beae
# ╟─f8b5b467-d1c6-4849-9a40-000fb0de92ef
# ╟─28e64f94-a97a-4573-b224-9d193bea4343
# ╟─66dd1933-a014-4280-a510-c9f686fa94a8
# ╟─758c6b95-f828-4f47-a753-329a8e92856f
# ╟─faf4da2d-d5f3-47e0-9faa-88ede775dce1
# ╟─4a7f4066-8c34-4afe-ba50-20fc7d98f88e
# ╟─014b1ac1-7b6d-4822-900c-9c595648c52d
# ╟─094d6dff-3e6a-49ff-96e0-e4f3c9173600
# ╟─2311d696-a68f-4d0a-aab5-4fda9cf2e070
# ╟─03e05ebd-c867-4789-a1cc-6d0ac4678ac0
# ╟─4df2223f-4a13-4b0b-97a7-12e6d463484c
# ╟─d0e7edbd-945e-4b0c-a7a8-9eb0067e8340
# ╟─f8a99808-da26-4537-ad0a-9b62343e9eb8
# ╟─aa19fa99-b102-4cc4-b51f-33ae280c5a0b
# ╠═61610f65-fecb-451b-b305-31bbc85e231d
# ╠═8475b95a-3642-4cac-8de1-305ce15489c8
# ╟─dcbfab0f-f733-4ea7-a642-aaa69daaa2ec
# ╠═6ffb3595-ab53-4483-bde6-f4db4becec9e
# ╟─e9b6a04a-3c07-4892-a873-4ed4b75b8e2e
# ╟─5f74bee1-af3e-49b2-9353-a87fff5a6d90
# ╟─51186111-e7e0-41ad-97e3-d15744cd494a
# ╟─d6ceb0fd-76e9-4ea0-8fb4-eb289e0567dc
# ╠═42ebb7aa-b91e-4f08-a161-f99d6395a6c3
# ╟─c695b023-f6c1-43e4-baa7-35b037475e15
# ╟─835d7096-35bd-49ee-ac06-2c96adc82159
# ╟─20ee6d16-6917-4efc-92b7-0d8235da5d9e
# ╟─be088865-2763-43f4-8dca-2cc733d681a6
# ╠═0ef3125f-e635-4ca7-8a26-00e07ec3a265
# ╟─f4b1420e-af51-4efa-a81d-cf82884dc519
# ╟─13573751-41c7-4d6a-8d40-08e6392eb6a1
# ╟─c6d0a5e0-3fc9-45ba-a750-c7a656dc0841
# ╟─e616fb4c-4c2e-441e-bad8-0ff44caebca3
# ╟─b78843f7-66a3-430c-bdd6-5e079851a723
# ╠═e910fa15-fc25-4e09-9cac-6b1ef0da96f9
# ╟─10d02a49-9943-4016-afdb-ca11a80d8711
# ╟─41d90aba-8f92-4aa7-81ee-7ec6b3d652b6
# ╟─7b6844bc-e2ab-4b81-b745-d467ee56410b
# ╟─78d9fb11-e056-4bc2-a656-1e2baf417053
# ╟─be813c1b-5a05-4e82-8d5b-b750cd87239e
# ╟─cb4dc416-8aa3-4976-b84b-67a91051a338
# ╟─9e3cf607-3bf6-442f-aaf9-717f4243583d
# ╟─e145d20d-a00d-4921-9af9-ce60353ad2ce
# ╟─c3c0443b-ecf0-4ffd-b61f-7da543ee14e2
# ╟─c6046b2b-2253-4929-9438-e2a074a9de10
# ╟─6e5f6c54-4112-488d-96e4-a740a5d6c521
# ╟─630effa0-9f3d-4a55-abdd-b4e9549e046f
# ╠═ac31f43d-d3b0-44da-8d10-a7f7cd497669
# ╠═f663b179-ed6a-459d-9c7e-3807cf80239a
# ╠═267c58f5-d1d2-4141-a552-acb0ada0bf1f
# ╟─d9fa8250-3634-4b76-88d8-65e929f35b7d
# ╠═5efd5d67-c422-49c3-959c-ade66b38633d
# ╠═1124fbb3-18b4-41c2-958d-3d2d4dd40cfe
# ╠═5a63cad5-f874-4390-b78c-498ce2180c3f
# ╟─38cd5fb5-3f07-4a4e-bea4-57cdae02d798
# ╟─41bdc919-ddcc-40f4-bd16-3f5a26485529
# ╟─bec571ff-86c7-4fd7-afcd-c27595563824
# ╟─a36e80da-6780-44ca-9e00-a42af83e3657
# ╟─5ff9ad90-c472-4eb9-9b31-4c5dffe44145
# ╟─80defee2-8e56-4375-84dc-99bee48883da
# ╟─687fc8b5-77a8-4875-b5e9-f942684ac6b6
# ╟─69b6a4fe-c8f8-4371-abe1-906bc690d4a2
# ╟─8fcc69eb-9f6c-4fb1-a70c-80216eed306b
# ╟─90c5cf85-de79-43db-8cba-39fda06938e6
# ╟─03bc22e3-2afa-4139-b8a4-b801dd8d3f4d
# ╟─3921124d-4f08-4f3c-856b-ad876d31e2c1
# ╠═948eae34-738d-4c60-98b9-8b69b1eb9b68
# ╟─52292d94-5245-42b4-9c11-1c53dfc5d5fb
# ╠═614a469e-0530-4983-82a9-e521097d57a9
# ╟─41a134b8-0c8a-4d79-931d-5df7ea524f73
# ╟─42151898-a5a9-4677-aa0e-675e986bb41b
# ╠═c4b40ca8-00b0-4ea0-9793-f06adcb44f12
# ╟─ebee2d90-d2a8-44c1-ae0b-2823c007bf1d
# ╟─63a63ca9-841e-40d7-b314-d5582772b634
# ╟─0fbd9c29-c5b6-407d-931d-945d1b915cd2
# ╟─f960b309-0250-4692-96e0-a73f79f84c71
# ╟─a88dfb2e-6aba-4ceb-b20a-829ebd3243bd
# ╟─a16674b9-e4bf-4e12-a9c5-f67a61f24d7b
# ╠═38f354ec-0df3-4e19-9afb-5342c89b7275
# ╟─b6e0906e-6b76-44b8-a736-e7a872f8c2d7
# ╠═3e54bce5-faf9-4954-980f-5d70737a3494
# ╟─22a00cb0-5aca-492b-beec-407ac7ef13d4
# ╟─596f8aee-34f4-4304-abbe-7100383ce0d1
# ╟─8581d294-4d19-40dc-a10a-79e8922ecedb
# ╠═62d66917-ef2e-4e64-ae6d-c281b8e81b4f
# ╠═67d8f55d-bdbe-4407-bf9b-b34805edcb76
# ╠═34701d56-63d1-4f6d-b3d0-52705f4f8820
# ╠═92cbd9fb-2fdf-45ed-aed5-2cc772c09a93
# ╟─87cbc472-6330-4a27-b10f-b8d881b79249
# ╟─3476d181-ba67-4597-b05c-9caec23fa1e5
# ╟─b8b79a69-2bbb-4329-a1d0-3429230787c1
# ╟─37761f25-bf80-47ee-9fca-06fce1047364
# ╟─97df1403-7858-4715-856d-f330926a9bfd
# ╟─02d14966-9887-40cb-a04d-09774ff72d27
# ╟─a9ca100d-8881-4c31-9ab9-e987baf91e2c
# ╟─721893e8-9252-4fcd-9ef7-59b70bffb916
# ╟─8666701b-223f-4dfc-a4ff-aec17c7e0ab2
# ╟─1df5a84a-7ef3-43fc-8ffe-6a8245b31f8e
# ╟─f42d1915-3490-4ae4-bb19-ac1383f453dc
# ╟─87f1b50a-cb53-4aac-aed6-b3c7c36959b0
# ╟─10ce5116-edfa-4b1a-9f9f-7400e5b761ec
# ╟─c69f0a97-84d6-4fd9-bf02-4cfa2132a9c1
# ╠═aa35bdee-3d2c-49ff-9483-795e0024de0c
# ╟─3df21310-c44a-4132-acc0-a0db265a23a9
# ╟─7469895b-06d2-4832-b981-d62b14a80fa8
# ╟─8ce55cdd-6c1a-4fc3-843a-aa6ed1ad4c62
# ╟─15ffc121-b27c-4eec-a829-a05904215426
# ╟─0adbb1a4-6e19-40d5-8f9d-865d932cd745
# ╟─fd3a4158-5b98-4ddb-a8bd-3603259ee490
# ╟─ea70f8e7-e25b-49cc-8cc2-e25b1aef6b0a
# ╟─be2184a8-fed0-4a97-81cb-0b727f9c0444
# ╟─6619b9ae-2608-4c8d-9561-bc579d673651
# ╟─c5e1ae85-8168-4cce-9b20-1cf21393a49f
# ╟─3d28d1b4-9f99-44f6-97b5-110f675b5c22
# ╟─f532c661-79ad-4c30-8aec-0379a84a3204
# ╟─d84a9ab0-647a-4bb2-978d-4720b6588d9c
# ╟─d4e50757-e67c-4206-a943-c2793d1680ab
# ╠═84800e5c-9ce2-4a37-aa3c-8f8e7e3d708c
# ╟─83163af1-cdf7-4987-a159-17a19b70f65f
# ╟─63280424-98d6-406a-b392-e124dc9fd0cb
# ╟─115805d5-3084-4011-8268-071427dc7eea
# ╟─def2037e-0bd8-446d-aec2-714f4254b33a
# ╠═984c9a6d-68b5-42d6-8b45-73153bc97980
# ╠═b3387bae-78c6-4aa9-abdc-c49ae72f5658
# ╠═0604e53f-7eef-452c-9f8a-e96d17800254
# ╠═6ef79e5c-ae76-48f8-8f13-c000bbfdfc04
# ╠═91e63e47-f8e4-4a23-a8e3-2617879f8076
# ╟─b7e0fe81-b21d-4cff-ba63-e6db12f04c34
# ╟─4ec896f9-b226-4743-91c6-962fccc46db6
# ╠═7a12850f-364d-431f-b072-6038fe3c91e1
# ╟─07b61dbd-7561-4f42-82dd-2b2c9b9b81c2
# ╠═de229acf-26c1-4dcc-a2a4-c4babc1b63e6
# ╟─bff94ffa-73f5-4436-8655-cc8f359af8a8
# ╟─d740a3d1-6af9-4116-bd9b-3dd6a8899d0f
# ╠═452ba406-f073-467a-9064-b330fe9ce6cf
# ╠═e2d6629e-0512-43ab-adae-f916811b1fc7
# ╠═c5ce2443-745d-43ea-ac8f-4dbbe3169dd3
# ╠═2934b1d3-bf51-46f9-b408-6c2ff78c2625
# ╟─1889d002-ec77-445c-bdb1-eb3a09a84b29
# ╟─29335ecb-7469-49ed-8d59-d102254f1a48
# ╠═1db9b111-f2eb-4918-acc3-c49fa2a97640
# ╠═2e3ffb07-454e-4a21-994a-4ecb773511a3
# ╟─ca0241b1-d876-4f91-9530-972f4e29b4e9
# ╠═26218631-7a9e-474a-aebd-aaa3535f657d
# ╠═c07c0c3a-f256-4481-a9e0-ef37c9877b47
# ╟─00000000-0000-0000-0000-000000000001
# ╟─00000000-0000-0000-0000-000000000002

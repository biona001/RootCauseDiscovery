"""
    zscore(obs_data::AbstractMatrix{T}, intv_data::AbstractMatrix{T})
    zscore(obs_data::AbstractMatrix{T}, intv_data::AbstractVector{T})

Runs the Z-score method. Input 1 is n*p, input 2 is m*p (or p*1)
"""
function zscore(
        obs_data::AbstractMatrix{T}, 
        intv_data::AbstractMatrix{T}
    ) where T
    npatients, ngenes = size(intv_data)
    size(obs_data, 2) == ngenes || error("Both input should have same number of genes (columns)")

    # observational data's mean and std
    μ = mean(obs_data, dims=1)
    σ = std(obs_data, dims=1)

    # compute squared Z scores for each patient in interventional data
    zscore_intv = zeros(npatients, ngenes)
    for patient in 1:npatients
        zs = Float64[]
        for i in 1:ngenes
            push!(zs, abs2((intv_data[patient, i] - μ[i]) / σ[i]) )
        end
        zscore_intv[patient, :] .= zs
    end
    
    return zscore_intv
end

function zscore(
        obs_data::AbstractMatrix{T}, 
        intv_data::AbstractVector{T}
    ) where T
    ngenes = length(intv_data)
    size(obs_data, 2) == ngenes || error("Number of genes mismatch")

    # observational data's mean and std
    μ = mean(obs_data, dims=1)
    σ = std(obs_data, dims=1)

    # compute squared Z scores for each patient in interventional data
    zs = Float64[]
    for i in 1:ngenes
        push!(zs, abs2((intv_data[i] - μ[i]) / σ[i]) )
    end
    return zs
end

"""
    compute_permutations(z::Vector{T}; threshold=2, nshuffles=1)

Given z-score vector, returns a list of permutations that will be used for 
the Cholesky method. 

# Inputs
+ `z`: Z-score vector

# Optional inputs
+ `threshold`: z-score threshold used for finding the abberent set (smaller
    means more permutations)
+ `nshuffles`: how many permutations to try for each "middle guy"
"""
function compute_permutations(
        z::AbstractVector{T}; 
        threshold=2,
        nshuffles=1
    ) where T
    # subset of genes indices that are abberent
    idx1 = findall(x -> x > threshold, z)
    idx1_copy = copy(idx1)

    # these are the normal genes
    idx2 = setdiff(1:length(z), idx1)

    # one way of generating length(idx1) permutations, fixing idx2
    perms = Vector{Int}[]
    for i in eachindex(idx1)
        for _ in 1:nshuffles
            shuffle!(idx2)
            shuffle!(idx1)
            target = idx1_copy[i]
            index = findfirst(x -> x == target, idx1)
            idx1[1], idx1[index] = target, idx1[1]
            push!(perms, vcat(idx2, idx1))
        end
    end
    return perms
end

# note: Xobs is n by p (i.e. p genes, must transpose Xobs and Xint prior to input)
"""
    root_cause_discovery(Xobs, Xint, perm)

Given one permutation, run main algorithm for root cause discovery.
"""
function root_cause_discovery(
        Xobs::AbstractMatrix{T}, 
        Xint::AbstractVector{T},
        perm::AbstractVector{Int}; 
    ) where T
    n, p = size(Xobs)
    p == length(Xint) || error("dimension mismatch!")
    all(sort(perm) .== 1:p) || error("perm is not a permutation vector")
    
    # permute Xobs and Xint
    Xobs_perm = Xobs[:, perm]
    Xint_perm = Xint[perm]

    # estimate covariance and mean
    μ̂ = mean(Xobs_perm, dims=1) |> vec
    if n > p
        Σ̂ = cov(Xobs_perm)
#         Σ̂ = cov(LinearShrinkage(CommonCovariance(), :ss), Xobs_perm)
#         Σ̂ = cov(LinearShrinkage(DiagonalUnequalVariance(), :ss), Xobs_perm)
    else
        Σ̂ = cov(LinearShrinkage(DiagonalUnequalVariance(), :lw), Xobs_perm)
    end

    # ad-hoc way to ensure PSD
    min_eval = minimum(eigvals(Σ̂))
    if min_eval < 1e-6
        for i in 1:size(Σ̂, 1)
            Σ̂[i, i] += abs(min_eval) + 1e-6
        end
    end
    
    # compute cholesky
    L = cholesky(Σ̂)

    # solve for X̃ in LX̃ = Xint_perm - μ̂ 
    X̃ = zeros(p)
    ldiv!(X̃, L.L, Xint_perm - μ̂)
    
    # undo the permutations
    invpermute!(X̃, perm)

    return abs.(X̃)
end

function find_largest(X̃all::Vector{Vector{Float64}})
    p = length(X̃all)
    largest = Float64[]
    largest_idx = Int[]
    for X̃ in X̃all
        push!(largest, sort(X̃)[end])
        push!(largest_idx, findmax(X̃)[2])
    end
    return largest, largest_idx
end

function find_second_largest(X̃all::Vector{Vector{Float64}})
    p = length(X̃all)
    second_largest = Float64[]
    for X̃ in X̃all
        push!(second_largest, sort(X̃)[end-1])
    end
    return second_largest
end

"""
    reduce_genes(patient_id, y_idx, Xobs, Xint, ground_truth, method)

Assuming root cause gene for patient `patient_id` is unknown, we run Lasso on the each gene, 
pretending it is the root-cause-gene (to select a subset of genes from Xobs)
"""
function reduce_genes(
        patient_id, 
        y_idx::Int, # this col will be treated as response in Xobs when we run lasso
        Xobs::AbstractMatrix{Float64}, 
        Xint::AbstractMatrix{Float64},
        ground_truth::DataFrame, # this is only used to access sample ID in Xint
        method::String, # either "cv" or "largest_support"
    )
    n, p = size(Xobs)

    # response and design matrix for Lasso
    y = Xobs[:, y_idx]
    X = Xobs[:, setdiff(1:p, y_idx)]

    # fit lasso
    beta_final = nothing
    if method == "cv"
        cv = glmnetcv(X, y)
        beta_final = GLMNet.coef(cv)
        if count(!iszero, beta_final) == 0
            return reduce_genes(patient_id, y_idx, Xobs, Xint, group_truth, "nhalf")
        end
    elseif method == "largest_support"
        path = glmnet(X, y)
        beta_final = path.betas[:, end]
    elseif method == "nhalf" # ad-hoc method to choose ~n/2 number of non-zero betas
        path = glmnet(X, y)
        beta_final = path.betas[:, 1]
        best_ratio = abs(0.5 - count(!iszero, beta_final) / n)
        for beta in eachcol(path.betas)
            new_ratio = abs(0.5 - count(!iszero, beta) / n)
            if new_ratio < best_ratio
                best_ratio = new_ratio
                beta_final = beta
            end
        end
        beta_final = Vector(beta_final)
    else
        error("method should be `cv`, `largest_support`, or `nhalf`")
    end
    nz = count(!iszero, beta_final)
    println("Lasso found $nz non-zero entries")

    # for non-zero idx, find the original indices in Xobs, and don't forget to include y_idx
    # back to the set of selected variables
    selected_idx = findall(!iszero, beta_final)
    selected_idx[findall(x -> x ≥ y_idx, selected_idx)] .+= 1
    append!(selected_idx, y_idx)

    # return the subset of variables of Xobs that were selected
    Xobs_new = Xobs[:, selected_idx]
    i = findfirst(x -> x == patient_id, ground_truth[!, "Patient ID"])
    Xint_sample_new = Xint[i, selected_idx]

    return Xobs_new, Xint_sample_new, selected_idx
end

"""
    get_abberant_thresholds(z_vec::AbstractVector{T}, [threshold_min], 
        [threshold_max], [threshold_seq])

Computes a list of threshold values (defaults to 0.1:0.2:5) that are 
non-redundant based on the input z scores
"""
function get_abberant_thresholds(
        z_vec::AbstractVector{T};
        threshold_min=0.1, 
        threshold_max=5.0,
        threshold_seq=0.2
    ) where T
    threshold_raw = collect(threshold_min:threshold_seq:threshold_max)
    count_temp = 0
    threshold_new = T[]
    for threshold in threshold_raw
        if count(x -> x >= threshold, z_vec) > 0
            if count(x -> x <= threshold, z_vec) != count_temp
                count_temp = count(x -> x <= threshold, z_vec)
                push!(threshold_new, threshold)
            end
        end
    end
    return threshold_new
end

function root_cause_discovery_reduced_dimensional(
        Xobs_new::AbstractMatrix{Float64}, 
        Xint_sample_new::AbstractVector{Float64};
        nshuffles::Int = 1,
        thresholds::Union{Nothing, Vector{Float64}} = nothing
    )
    # first compute z score (needed to compute permutations)
    z = zscore(Xobs_new, Xint_sample_new') |> vec

    # if no thresholds are provided, compute default
    if isnothing(thresholds)
        thresholds = get_abberant_thresholds(z)
    end

    # root cause discovery by trying lots of permutations
    largest, largest_idx = Float64[], Int[]
    second_largest = Float64[]
    for threshold in thresholds
        permutations = compute_permutations(z; threshold=threshold, nshuffles=nshuffles)
        X̃all = Vector{Vector{Float64}}(undef, length(permutations))
        for i in eachindex(permutations)
            perm = permutations[i]
            X̃all[i] = root_cause_discovery(
                Xobs_new, Xint_sample_new, perm
            )
        end
        largest_cur, largest_idx_cur = find_largest(X̃all)
        append!(largest, largest_cur)
        append!(largest_idx, largest_idx_cur)
        append!(second_largest, find_second_largest(X̃all))
    end

    diff = largest-second_largest
    diff_normalized = diff ./ second_largest
    perm = sortperm(diff_normalized)

    # return root cause (cholesky) score for the current variable that is treated as response
    root_cause_score_y = 0.0
    for per in Iterators.reverse(perm)
        matched = size(Xobs_new, 2) == largest_idx[per]
        if matched
            root_cause_score_y = diff_normalized[per]
            break
        end
    end
    return root_cause_score_y

    # old code returns a table (sorted by largest - 2nd largest)
        # 4th col is (largest - 2nd largest) / (2nd largest)
        # 5th col is index of the largest element
        # 7th col is the index that is used as response in lasso regression
        # when 5th and 7th column match, we have "found" the root cause index
        # otherwise we didn't find the root cause index
    # result = [largest second_largest diff diff_normalized largest_idx z[largest_idx]][perm, :]
    # result = [result [size(Xobs_new, 2) for _ in 1:size(result, 1)]] # add correct to result purely for easier visualization
    # return result
end

"""
    root_cause_discovery_high_dimensional

High level wrapper for Root cause discovery, for p>n data. 
First guess many root causes, then runs lasso, then run root cause discovery algorithm.

Still need a way to check if guesses are "root causes"
"""
function root_cause_discovery_high_dimensional(
        patient_id::String,
        Xobs::AbstractMatrix{Float64}, 
        Xint::AbstractMatrix{Float64},
        ground_truth::DataFrame, # this is only used to access sample ID in Xint
        method::String; # either "cv" or "largest_support"
        y_idx_z_threshold=1.5,
        nshuffles::Int = 1,
        verbose = true,
        thresholds::Union{Nothing, Vector{Float64}} = nothing,
    )
    p = size(Xobs, 2)

    # compute some guesses for root cause index
    i = findfirst(x -> x == patient_id, ground_truth[!, "Patient ID"])
    Xint_sample = Xint[i, :]
    z = zscore(Xobs, Xint_sample') |> vec
    y_indices = compute_y_idx(z, z_threshold=y_idx_z_threshold)
    verbose && println("Trying $(length(y_indices)) y_idx")
    
    # run root cause algorithm on selected y
    root_cause_scores = zeros(p)
    Threads.@threads for y_idx in y_indices
        # run lasso, select gene subset to run root cause discovery
        Xobs_new, Xint_sample_new, _ = reduce_genes(
            patient_id, y_idx, Xobs, Xint, ground_truth, method
        )

        # compute current guess of root cause index
        root_cause_scores[y_idx] = root_cause_discovery_reduced_dimensional(
            Xobs_new, Xint_sample_new, nshuffles=nshuffles, thresholds=thresholds
        )
    end

    # assign final root cause score for variables that never had max Xtilde_i
    idx2 = findall(iszero, root_cause_scores)
    idx1 = findall(!iszero, root_cause_scores)
    if length(idx2) != 0
        if length(idx1) != 0
            max_RC_score_idx = minimum(root_cause_scores[idx1]) - 0.00001
            root_cause_scores[idx2] .= z[idx2] ./ (maximum(z[idx2]) ./ max_RC_score_idx)
        else
            # use z scores when everything is 0
            root_cause_scores = z
        end
    end

    return root_cause_scores
end

"""
    compute_y_idx(z::AbstractVector{Float64})

Given some Z scores, compute a set of variables that will be treated as "root causes", and enter the 
root-cause-discovery algorirthm
"""
function compute_y_idx(z::AbstractVector{Float64}; z_threshold=1.5)
    return findall(x -> x > z_threshold, z)
end

# """
# This function is specific for our real-data application (`ground_truth`
# is based on real data). 

# Given a patient, we compute its Z-score rank, and then try to refine
# its rank via the RCD method. Note: if the root cause was not used as
# the response in lasso regression, its refined rank will be `Inf`
# """
# function refine_z_score_rank(
#         patient_id::AbstractString,
#         ground_truth::DataFrame,
#         Xobs::AbstractMatrix,
#         Xint::AbstractMatrix,
#         lasso_method::String; #cv or largest_support
#         max_acceptable_zscore = 1.5,
#     )
#     jld2_file = "/scratch/users/bbchu/RootCauseDiscovery/result_3.25.2024/$(lasso_method)/$(patient_id).jld2"
#     results = JLD2.load(jld2_file, "results")
#     y_indices = JLD2.load(jld2_file, "y_indices")

#     # compute z scores
#     Xint_sample = Xint[findfirst(x -> x == patient_id, ground_truth[!, "Patient ID"]), :]
#     z = RootCauseDiscovery.zscore(Xobs, Xint_sample') |> vec

#     # compute root cause index
#     root_cause_idx = ground_truth[findfirst(x -> x == patient_id, ground_truth[!, "Patient ID"]), end]
#     if root_cause_idx ∉ y_indices
#         println("The root cause was not chosen as a y for lasso")
#         return Inf # return Inf when the root cause idx was not chosen as a y for lasso
#     end

#     # other needed quantities
#     root_cause_zscore = z[root_cause_idx]
#     row_of_rootcause_in_result = findfirst(x -> x == root_cause_idx, y_indices)

#     # for each gene w/ z score > 1.5, check its permutation table
#     # to see if desired pattern exist
#     matched = falses(length(results)) # length(matched) == length(results) == length(y_indices) 
#     for (i, result) in enumerate(results)
#         row = findlast(x -> x > max_acceptable_zscore, result[:, 6])
#         if !isnothing(row)
#             if result[row, 5] == result[row, 7]
#                 matched[i] = true
#             end
#         end
#     end

#     # calculate the refined rank for root cause
#     root_cause_matched = matched[row_of_rootcause_in_result]
#     if root_cause_matched
#         # for all matching patterns, count how many have z scores
#         # larger than the root cause
#         counter = 0
#         for (i, yi) in enumerate(y_indices)
#             if (matched[i] == true) && (z[yi] > root_cause_zscore)
#                 counter += 1
#             end
#         end
#         rk = counter
#     else
#         # if root cause index did not have desired matching pattern,
#         # then if there's a matched variable, or the variable has larger Z score,
#         # the variable will be ranked before the root cause
#         counter = 0
#         for (i, yi) in enumerate(y_indices)
#             if (matched[i] == true) || (z[yi] > root_cause_zscore)
#                 counter += 1
#             end
#         end
#         rk = counter
#     end
#     return rk
# end
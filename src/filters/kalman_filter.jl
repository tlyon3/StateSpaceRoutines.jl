#= #
This code is loosely based on a routine originally copyright Federal Reserve Bank of Atlanta
and written by Iskander Karibzhanov.
=#

mutable struct Kalman_Out
    z               ::Array{Float64, 1}
    P               ::Array{Float64, 2}
    pred            ::Array{Float64, 2}
    vpred           ::Array{Float64, 3}
    filt            ::Array{Float64, 2}
    vfilt           ::Array{Float64, 3}
    yprederror      ::Array{Float64, 2}
    ystdprederror   ::Array{Float64, 2}
    z0              ::Array{Float64, 1}
    P0              ::Array{Float64, 2}
    marginal_loglh  ::Array{Float64, 1}
end

# These can all be computed from other values
# rmse            ::Array{Float64, 2}
# rmsd            ::Array{Float64, 2}
# log_likelihood  ::Float64

# log_likelihood = sum(marginal_loglh)
#
# # if allout
# rmse = sqrt.(mean((yprederror.^2), 2))'
# rmsd = sqrt.(mean((ystdprederror.^2), 2))'


"""
```
kalman_filter(data, TTT, RRR, CCC, QQ, ZZ, DD, EE, z0 = Vector(), P0 = Matrix();
    allout = true, n_presample_periods = 0)

kalman_filter(regime_indices, data, TTTs, RRRs, CCCs, QQs, ZZs, DDs,
    EEs, z0 = Vector(), P0 = Matrix(); allout = true, n_presample_periods = 0)
```

This function implements the Kalman filter for the following state-space model:

```
z_{t+1} = CCC + TTT*z_t + RRR*ϵ_t    (transition equation)
y_t     = DD  + ZZ*z_t  + η_t        (measurement equation)

ϵ_t ∼ N(0, QQ)
η_t ∼ N(0, EE)
Cov(ϵ_t, η_t) = 0
```

### Inputs

- `data`: `Ny` x `T` matrix containing data `y(1), ... , y(T)`
- `z0`: optional `Nz` x 1 initial state vector
- `P0`: optional `Nz` x `Nz` initial state covariance matrix

**Method 1 only:**

- `TTT`: `Nz` x `Nz` state transition matrix
- `RRR`: `Nz` x `Ne` matrix in the transition equation mapping shocks to states
- `CCC`: `Nz` x 1 constant vector in the transition equation
- `QQ`: `Ne` x `Ne` matrix of shock covariances
- `ZZ`: `Ny` x `Nz` matrix in the measurement equation mapping states to
  observables
- `DD`: `Ny` x 1 constant vector in the measurement equation
- `EE`: `Ny` x `Ny` matrix of measurement error covariances

**Method 2 only:**

- `regime_indices`: `Vector{Range{Int64}}` of length `n_regimes`, where
  `regime_indices[i]` indicates the time periods `t` in regime `i`
- `TTTs`: `Vector{Matrix{S}}` of `TTT` matrices for each regime
- `RRRs`
- `CCCs`
- `QQs`
- `ZZs`
- `DDs`
- `EEs`

where:

- `T`: number of time periods for which we have data
- `Nz`: number of states
- `Ne`: number of shocks
- `Ny`: number of observables

### Keyword Arguments

- `allout`: indicates whether we want to return all values. If `!allout`, then
  we return only the likelihood, `z_{T|T}`, and `P_{T|T}`.
- `n_presample_periods`: if greater than 0, the first `n_presample_periods` will
  be omitted from the likelihood calculation and all return values

### Outputs

- `log_likelihood`: log likelihood of the state-space model
- `zend`: `Nz` x 1 final filtered state `z_{T|T}`
- `Pend`: `Nz` x `Nz` final filtered state covariance matrix `P_{T|T}`
- `pred`: `Nz` x `T` matrix of one-step predicted state vectors `z_{t|t-1}`
- `vpred`: `Nz` x `Nz` x `T` array of mean squared errors `P_{t|t-1}` of
  predicted state vectors
- `filt`: `Nz` x `T` matrix of filtered state vectors `z_{t|t}`
- `vfilt`: `Nz` x `Nz` x `T` matrix containing mean squared errors `P_{t|t}` of
  filtered state vectors
- `yprederror`: `Ny` x `T` matrix of observable prediction errors
  `y_t - y_{t|t-1}`
- `ystdprederror`: `Ny` x `T` matrix of standardized observable prediction errors
  `V_{t|t-1} \ (y_t - y_{t|t-1})`, where `y_t - y_{t|t-1} ∼ N(0, V_{t|t-1}`
- `rmse`: 1 x `T` row vector of root mean squared prediction errors
- `rmsd`: 1 x `T` row vector of root mean squared standardized prediction errors
- `z0`: `Nz` x 1 initial state vector. This may have reassigned to the last
  presample state vector if `n_presample_periods > 0`
- `P0`: `Nz` x `Nz` initial state covariance matrix. This may have reassigned to
  the last presample state covariance if `n_presample_periods > 0`
- `marginal_loglh`: a vector of the marginal log likelihoods from t = 1 to T

### Notes

When `z0` and `P0` are omitted, the initial state vector and its covariance
matrix of the time invariant Kalman filters are computed under the stationarity
condition:

```
z0  = (I - TTT)\CCC
P0 = reshape(I - kron(TTT, TTT))\vec(RRR*QQ*RRR'), Nz, Nz)
```

where:

- `kron(TTT, TTT)` is a matrix of dimension `Nz^2` x `Nz^2`, the Kronecker
  product of `TTT`
- `vec(RRR*QQ*RRR')` is the `Nz^2` x 1 column vector constructed by stacking the
  `Nz` columns of `RRR*QQ*RRR'`

All eigenvalues of `TTT` are inside the unit circle when the state space model
is stationary.  When the preceding formula cannot be applied, the initial state
vector estimate is set to `CCC` and its covariance matrix is given by `1e6 * I`.
"""
function kalman_filter{S<:AbstractFloat}(regime_indices::Vector{Range{Int64}},
    data::Matrix{S}, TTTs::Vector{Matrix{S}}, RRRs::Vector{Matrix{S}}, CCCs::Vector{Vector{S}},
    QQs::Vector{Matrix{S}}, ZZs::Vector{Matrix{S}}, DDs::Vector{Vector{S}}, EEs::Vector{Matrix{S}},
    z0::Vector{S} = Vector{S}(), P0::Matrix{S} = Matrix{S}(),
    allout::Bool = true, n_presample_periods::Int = 0)

    # Dimensions
    T  = size(data,    2) # number of periods of data
    Nz = size(TTTs[1], 1) # number of states
    Ny = size(ZZs[1],  1) # number of observables

    @assert first(regime_indices[1]) == 1
    @assert last(regime_indices[end]) == T

    # Initialize outputs
    if allout
        out_kf = Kalman_Out(
            z0,                                          # z
            P0,                                          # P
            zeros(S, Nz, T - n_presample_periods),      # pred
            zeros(S, Nz, Nz, T - n_presample_periods),  # vpred
            zeros(S, Nz, T - n_presample_periods),      # filt
            zeros(S, Nz, Nz, T - n_presample_periods),  # vfilt
            zeros(S, Ny, T - n_presample_periods),      # yprederror
            zeros(S, Ny, T - n_presample_periods),      # ystdprederror
            z,                                          # z0
            P,                                          # P0
            zeros(T - n_presample_periods)              # marginal_loglh
        )
    else
        out_kf = Kalman_Out(
            z0,                             # z
            P0,                             # P
            Array{Float64}(0, 0),           # pred
            Array{Float64}(0, 0, 0),        # vpred
            Array{Float64}(0, 0),           # filt
            Array{Float64}(0, 0, 0),        # vfilt
            Array{Float64}(0, 0),           # yprederror
            Array{Float64}(0, 0),           # ystdprederror
            z0,                             # z0
            P0,                             # P0
            zeros(T - n_presample_periods)  # marginal_loglh
        )
    end

    # Iterate through regimes
    new_kf = out_kf
    for i = 1:length(regime_indices)
        regime_data = data[:, regime_indices[i]]
        if i == 1
            T0 = n_presample_periods
            ts = 1:(last(regime_indices[i]) - n_presample_periods)
        else
            T0 = 0
            ts = regime_indices[i] - n_presample_periods
        end

        if allout
            # TODO: need to use the previous `z` and `p` here...
            new_kf = kalman_filter(regime_data, TTTs[i], RRRs[i], CCCs[i],
                                    QQs[i], ZZs[i], DDs[i], EEs[i],
                                    new_kf.z, new_kf.P; allout = true,
                                    n_presample_periods = T0)

            # If `n_presample_periods > 0`, then `z0_` and `P0_` are returned as
            # the filtered values at the end of the presample/beginning of the
            # main sample (i.e. not the same the `z0` and `P0` passed into this
            # method, which are from the beginning of the presample). If we are
            # in the first regime, we want to reassign `z0` and `P0`
            # accordingly.
            if i == 1
                out_kf.z0, out_kf.P0 = new_kf.z0_, new_kf.P0_
            end
        else
            # TODO: need to use the previous `z` and `p` here...
            new_kf = kalman_filter(regime_data, TTTs[i], RRRs[i], CCCs[i],
                                    QQs[i], ZZs[i], DDs[i], EEs[i],
                                    new_kf.z, new_kf.P; allout = false,
                                    n_presample_periods = T0)
        end
        # TODO: This gets summed....can't compute after??????
        log_likelihood += log_likelihood(new_kf)
    end

    return out_kf
end

function kalman_filter{S<:AbstractFloat}(data::Matrix{S},
    TTT::Matrix{S}, RRR::Matrix{S}, CCC::Vector{S},
    QQ::Matrix{S}, ZZ::Matrix{S}, DD::Vector{S}, EE::Matrix{S},
    z0::Vector{S} = Vector{S}(), P0::Matrix{S} = Matrix{S}(0,0),
    allout::Bool = true, n_presample_periods::Int = 0)


    # Dimensions
    T  = size(data, 2) # number of periods of data
    Nz = size(TTT,  1) # number of states
    Ne = size(RRR,  2) # number of shocks
    Ny = size(ZZ,   1) # number of observables

    # Populate initial conditions if they are empty
    if isempty(z0) || isempty(P0)
        e, _ = eig(TTT)
        if all(abs.(e) .< 1.)
            z0 = (UniformScaling(1) - TTT)\CCC
            P0 = solve_discrete_lyapunov(TTT, RRR*QQ*RRR')
        else
            z0 = CCC
            P0 = 1e6 * eye(Nz)
        end
    end

    # Initialize outputs
    # marginal_logtlh = zeros(T)
    if allout
        kf = Kalman_Out(
            z0,                     #z
            P0,                     #P
            zeros(S, Nz, T),        #pred
            zeros(S, Nz, Nz, T),    #vpred
            zeros(S, Nz, T),        #filt
            zeros(S, Nz, Nz, T),    #vfilt
            NaN*zeros(S, Ny, T),    #yprederror
            NaN*zeros(S, Ny, T),    #ystdprederror
            z0,                     #z0
            P0,                     #P0
            zeros(T)                #marginal_loglh
        )
    else
        kf = Kalman_Out(
            z0,                         # z
            P0,                         # P
            Array{Float64}(0, 0),       # pred
            Array{Float64}(0, 0, 0),    # vpred
            Array{Float64}(0, 0),       # filt
            Array{Float64}(0, 0, 0),    # vfilt
            Array{Float64}(0, 0),       # yprederror
            Array{Float64}(0, 0),       # ystdprederror
            z0,                         # z0
            P0,                         # P0
            zeros(T)                    # marginal_loglh
        )
    end

    V = RRR*QQ*RRR' # V = Var(z_t) = Var(Rϵ_t)
    V_0 = copy(V)

    nonmissing = BitVector(size(data, 1))

    for t = 1:T
        # Index out rows of the measurement equation for which we have
        # nonmissing data in period t

        # nonmissing = .!isnan.(data[:, t])
        @inbounds @simd for row in 1:size(data,1) # size is already known
            nonmissing[row] = !isnan(data[row, t])
        end

        y_t  = data[nonmissing, t]
        ZZ_t = ZZ[nonmissing, :]
        DD_t = DD[nonmissing]
        EE_t = EE[nonmissing, nonmissing]
        Ny_t = length(y_t)

        ## Forecast
        kf.z = TTT*kf.z + CCC                 # z_{t|t-1} = TTT*z_{t-1|t-1} + CCC
        kf.P = TTT*kf.P*TTT' + V_0            # P_{t|t-1} = Var s_{t|t-1} = TTT*P_{t-1|t-1}*TTT' + RRR*QQ*RRR'
        V = ZZ_t*kf.P*ZZ_t' + EE_t         # V_{t|t-1} = Var y_{t|t-1} = ZZ*P_{t|t-1}*ZZ' + EE
        V = (V+V')/2

        dy = y_t - ZZ_t*kf.z - DD_t        # dy  = y_t - y_{t|t-1} = prediction error
        ddy = V\dy                      # ddy = (1/V_{t|t-1})dy = weighted prediction error

        if allout
            kf.pred[:, t]                   = kf.z
            kf.vpred[:, :, t]               = kf.P
            kf.yprederror[nonmissing, t]    = dy
            kf.ystdprederror[nonmissing, t] .= dy ./ sqrt.(diag(V))
        end

        ## Compute marginal log-likelihood, log P(y_t|y_1,...y_{t-1},θ)
        ## log P(y_1,...,y_T|θ) ∝ log P(y_1|θ) + log P(y_2|y_1,θ) + ... + P(y_T|y_1,...,y_{T-1},θ)
        if t > n_presample_periods
            kf.marginal_loglh[t] = -log(det(V))/2 - first(dy'*ddy/2) - Ny_t*log(2*pi)/2
        end

        gain = kf.P'*ZZ_t'
        ## Update
        kf.z = kf.z + gain*ddy            # z_{t|t} = z_{t|t-1} + P_{t|t-1}'*ZZ'*(1/V_{t|t-1})dy
        kf.P = kf.P - gain/V*ZZ_t*kf.P       # P_{t|t} = P_{t|t-1} - P_{t|t-1}'*ZZ'*(1/V_{t|t-1})*ZZ*P_{t|t-1}

        if allout
            kf.filt[:, t]     = kf.z
            kf.vfilt[:, :, t] = kf.P
        end

    end # of loop through periods

    if n_presample_periods > 0
        mainsample_periods = n_presample_periods+1:T

        kf.marginal_loglh = kf.marginal_loglh[mainsample_periods]

        if allout
            # If we choose to discard presample periods, then we reassign `z0`
            # and `P0` to be their values at the end of the presample/beginning
            # of the main sample
            kf.z0 = filt[:,     n_presample_periods]
            kf.P0 = vfilt[:, :, n_presample_periods]

            kf.pred            = pred[:,     mainsample_periods]
            kf.vpred           = vpred[:, :, mainsample_periods]
            kf.filt            = filt[:,     mainsample_periods]
            kf.vfilt           = vfilt[:, :, mainsample_periods]
            kf.yprederror      = yprederror[:,  mainsample_periods]
            kf.ystdprederror   = ystdprederror[:, mainsample_periods]
        end
    end

    return kf
end

function log_likelihood(kf::Kalman_Out)
    return sum(kf.marginal_loglh)
end

# function log_likelihood(marginal_loglh::Array{Float64, 1})
#     return sum(marginal_loglh)
# end

function rmse(kf::Kalman_Out)
    return sqrt.(mean((kf.yprederror.^2), 2))'
end

# function rmse(yprederror::Array{Float64, 2})
#     return sqrt.(mean((yprederror.^2), 2))'
# end

function rmsd(kf::Kalman_Out)
    return sqrt.(mean((kf.ystdprederror.^2), 2))'
end

# function rmsd(ystdprederror::Kalman_Out)
#     return sqrt.(mean((ystdprederror.^2), 2))'
# end

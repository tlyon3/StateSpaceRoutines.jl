#=
This code is loosely based on a routine originally copyright Federal Reserve Bank of Atlanta
and written by Iskander Karibzhanov.
=#

"""
```
kalman_filter{S<:AbstractFloat}(data::Matrix{S},
    TTT::Matrix{S}, CCC::Vector{S}, ZZ::Matrix{S}, DD::Vector{S}, VVall::Matrix{S},
    z0::Vector{S} = Vector{S}(), P0::Matrix{S} = Matrix{S}();
    likelihood_only::Bool = false)
```

### Inputs

- `data`: a `Ny` x `T` `Matrix` containing data `y(1), ... , y(T)`.
- `TTT`: an `Nz` x `Nz` `Matrix` for a time-invariant transition matrix in the transition
  equation.
- `CCC`: an `Nz` x 1 `Vector` for a time-invariant input vector in the transition equation.
- `ZZ`: an `Ny` x `Nz` `Matrix` for a time-invariant measurement matrix in the measurement
  equation.
- `DD`: an `Ny` x 1 constant vector in measurement equation
- `VVall`: See `Measurement` type for description

#### Optional Inputs
- `z0`: an optional `Nz` x 1 initial state vector.
- `P0`: an optional `Nz` x `Nz` covariance matrix of an initial state vector.
- `likelihood_only`: an optional keyword argument indicating whether we want optional output
  variables returned as well

Where:

- `Nz`: number of states
- `Ny`: number of observables
- `T`: number of time periods for which we have data

### Outputs

- a `Kalman` object. See documentation for `Kalman`.

### Notes

The state space model is defined as follows:
```
z(t+1) = CCC + TTT*z(t) + RRR*ϵ(t)   (state or transition equation)
y(t) = DD + ZZ*z(t) + u(t)           (observation or measurement equation)
```

When `z0` and `P0` are omitted, the initial state vector and its covariance
matrix of the time invariant Kalman filters are computed under the stationarity
condition:
```
z0  = (I - TTT)\CCC
P0 = reshape(I - kron(TTT, TTT))\vec(V), Nz, Nz)
```

Where:

- `kron(TTT, TTT)` is a matrix of dimension `Nz^2` x `Nz^2`, the Kronecker
  product of `TTT`
- `vec(V)` is the `Nz^2` x 1 column vector constructed by stacking the `Nz`
  columns of `V`

All eigenvalues of `TTT` are inside the unit circle when the state space model
is stationary.  When the preceding formula cannot be applied, the initial state
vector estimate is set to `CCC` and its covariance matrix is given by `1e6 * I`.
"""
function kalman_filter{S<:AbstractFloat}(data::Matrix{S},
    TTT::Matrix{S}, RRR::Matrix{S}, CCC::Vector{S},
    QQ::Matrix{S}, ZZ::Matrix{S}, DD::Vector{S}, MM::Matrix{S}, EE::Matrix{S},
    z0::Vector{S} = Vector{S}(), P0::Matrix{S} = Matrix{S}();
    likelihood_only::Bool = false, n_presample_periods::Int = 0)

    T = size(data, 2)
    regime_indices = Range{Int64}[1:T]

    kalman_filter(regime_indices, data, Matrix{S}[TTT], Matrix{S}[RRR], Vector{S}[CCC],
        Matrix{S}[QQ], Matrix{S}[ZZ], Vector{S}[DD],
        Matrix{S}[MM], Matrix{S}[EE], z0, P0;
        likelihood_only = likelihood_only, n_presample_periods = n_presample_periods)
end

function kalman_filter{S<:AbstractFloat}(regime_indices::Vector{Range{Int64}},
    data::Matrix{S}, TTTs::Vector{Matrix{S}}, RRRs::Vector{Matrix{S}}, CCCs::Vector{Vector{S}},
    QQs::Vector{Matrix{S}}, ZZs::Vector{Matrix{S}}, DDs::Vector{Vector{S}},
    MMs::Vector{Matrix{S}}, EEs::Vector{Matrix{S}},
    z0::Vector{S} = Vector{S}(), P0::Matrix{S} = Matrix{S}();
    likelihood_only::Bool = false, n_presample_periods::Int = 0)

    n_regimes = length(regime_indices)

    # Dimensions
    T  = size(data,    2) # number of periods of data
    Nz = size(TTTs[1], 1) # number of states
    Ne = size(RRRs[1], 2) # number of shocks
    Ny = size(ZZs[1],  1) # number of observables

    # Populate initial conditions if they are empty
    if isempty(z0) || isempty(P0)
        e, _ = eig(TTTs[1])
        if all(abs(e) .< 1.)
            z0 = (UniformScaling(1) - TTTs[1])\CCCs[1]
            P0 = solve_discrete_lyapunov(TTTs[1], RRRs[1]*QQs[1]*RRRs[1]')
        else
            z0 = CCC
            P0 = 1e6 * eye(Nz)
        end
    end

    z = z0
    P = P0

    # Initialize outputs
    if !likelihood_only
        pred          = zeros(S, Nz, T)
        vpred         = zeros(S, Nz, Nz, T)
        yprederror    = NaN*zeros(S, Ny, T)
        ystdprederror = NaN*zeros(S, Ny, T)
        filt          = zeros(Nz, T)
        vfilt         = zeros(Nz, Nz, T)
    end

    log_likelihood = 0.0

    for i = 1:n_regimes
        # Get state-space system matrices for this regime
        regime_periods = regime_indices[i]
        regime_data = data[:, regime_periods]

        TTT, RRR, CCC = TTTs[i], RRRs[i], CCCs[i]
        QQ,  ZZ,  DD  = QQs[i],  ZZs[i],  DDs[i]
        MM,  EE       = MMs[i],  EEs[i]

        V = RRR*QQ*RRR'    # V = Var(z_t) = Var(Rϵ_t)
        R = EE + MM*QQ*MM' # R = Var(y_t) = Var(u_t)
        G = RRR*QQ*MM'     # G = Cov(z_t, y_t)

        for t in regime_periods
            # If an element of the vector y_t is missing (NaN) for the observation t, the
            # corresponding row is ditched from the measurement equation
            nonmissing = !isnan(data[:, t])
            y_t  = data[nonmissing, t]
            ZZ_t = ZZ[nonmissing, :]
            G_t  = G[:, nonmissing]
            R_t  = R[nonmissing, nonmissing]
            Ny_t = length(y_t)
            DD_t = DD[nonmissing]

            ## Forecast
            z = CCC + TTT*z                    # z_{t|t-1} = CCC + TTT*z_{t-1|t-1}
            P = TTT*P*TTT' + V                 # P_{t|t-1} = TTT*P_{t-1|t-1}*TTT' + TTT*Var(η_t)*TTT'
            dy = y_t - ZZ_t*z - DD_t           # dy = y_t - ZZ*z_{t|t-1} - DD is prediction error or innovation
            ZG = ZZ_t*G_t                      # ZG is ZZ*Cov(η_t, ϵ_t)
            D = ZZ_t*P*ZZ_t' + ZG + ZG' + R_t  # D = ZZ*P_{t|t-1}*ZZ' + ZG + ZG' + R_t
            D = (D+D')/2

            if !likelihood_only
                pred[:, t]                   = z
                vpred[:, :, t]               = P
                yprederror[nonmissing, t]    = dy
                ystdprederror[nonmissing, t] = dy ./ sqrt(diag(D))
            end

            ddy = D\dy

            # We evaluate the log likelihood function by adding values of L at every iteration
            # step (for each t = 1,2,...T)
            if t > n_presample_periods
                log_likelihood += -log(det(D))/2 - first(dy'*ddy/2) - Ny_t*log(2*pi)/2
            end

            ## Update
            PZG = P*ZZ_t' + G_t
            z = z + PZG*ddy                    # z_{t|t} = z_{t|t-1} + P_{t|t-1}*ZZ(Θ)' + ...
            P = P - PZG/D*PZG'                 # P_{t|t} = P_{t|t-1} - PZG*(1/D)*PZG

            if !likelihood_only
                filt[:, t]     = z
                vfilt[:, :, t] = P
            end

        end # of loop through this regime's periods

    end # of loop through regimes

    zend = z
    Pend = P

    if !likelihood_only && n_presample_periods > 0
        mainsample_periods = n_presample_periods+1:T

        # If we choose to discard presample periods, then we reassign `z0`
        # and `P0` to be their values at the end of the presample/beginning
        # of the main sample
        z0 = squeeze(filt[:,     n_presample_periods], 2)
        P0 = squeeze(vfilt[:, :, n_presample_periods], 3)

        pred          = pred[:,     mainsample_periods]
        vpred         = vpred[:, :, mainsample_periods]
        yprederror    = yprederror[:,       mainsample_periods]
        ystdprederror = ypredstderror[:, :, mainsample_periods]
        filt          = filt[:,      mainsample_periods]
        vfilt         = vfilt[:, :, mainsample_periods]
    end

    if !likelihood_only
        rmse = sqrt(mean((yprederror.^2)', 1))
        rmsd = sqrt(mean((ystdprederror.^2)', 1))

        return log_likelihood, zend, Pend, pred, vpred, yprederror, ystdprederror, rmse, rmsd, filt, vfilt, z0, P0
    else
        return log_likelihood
    end
end
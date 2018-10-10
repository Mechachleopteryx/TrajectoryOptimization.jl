# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# FILE CONTENTS:
#     SUMMARY: Forward and Backward passes for iLQR algorithm
#
#     backwardpass!: iLQR backward pass
#     backwardpass_sqrt: iLQR backward pass with Cholesky Factorization of
#        Cost-to-Go
#     backwardpass_foh!: iLQR backward pass for first order hold on controls
#     chol_minus: Calculate sqrt(A-B)
#     forwardpass!: iLQR forward pass
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

"""
$(SIGNATURES)
Solve the dynamic programming problem, starting from the terminal time step
Computes the gain matrices K and d by applying the principle of optimality at
each time step, solving for the gradient (s) and Hessian (S) of the cost-to-go
function. Also returns parameters Δv for line search (see Synthesis and Stabilization of Complex Behaviors through
Online Trajectory Optimization)
"""
function backwardpass!(res::SolverVectorResults,solver::Solver)
    N = solver.N; n = solver.model.n; m = solver.model.m;
    Q = solver.obj.Q; Qf = solver.obj.Qf; xf = solver.obj.xf;
    R = getR(solver)
    dt = solver.dt

    # check if infeasible start solve
    if solver.model.m != length(res.U[1])
        m += n
    end

    # pull out values from results
    X = res.X; U = res.U; K = res.K; d = res.d; S = res.S; s = res.s

    # Boundary Conditions
    S[N] = Qf
    s[N] = Qf*(X[N] - xf)

    # Initialize expected change in cost-to-go
    Δv = [0.0 0.0]

    # Terminal constraints
    if res isa ConstrainedIterResults
        C = res.C; Iμ = res.Iμ; LAMBDA = res.LAMBDA
        CxN = res.Cx_N
        S[N] += CxN'*res.IμN*CxN
        s[N] += CxN'*res.IμN*res.CN + CxN'*res.λN
    end


    # Backward pass
    k = N-1
    while k >= 1

        lx = dt*Q*vec(X[k] - xf)
        lu = dt*R*vec(U[k])
        lxx = dt*Q
        luu = dt*R

        # Compute gradients of the dynamics
        fx, fu = res.fx[k], res.fu[k]

        # Gradients and Hessians of Taylor Series Expansion of Q
        Qx = lx + fx'*vec(s[k+1])
        Qu = lu + fu'*vec(s[k+1])
        Qxx = lxx + fx'*S[k+1]*fx

        Quu = luu + fu'*S[k+1]*fu
        Qux = fu'*S[k+1]*fx

        # Note: it is critical to have a separate, regularized Quu, Qux for the gains and unregularized versions for S,s to propagate backward
        if solver.opts.regularization_type == :state
            Quu_reg = luu + fu'*(S[k+1] + res.ρ[1]*I)*fu
            Qux_reg = fu'*(S[k+1] + res.ρ[1]*I)*fx
        elseif solver.opts.regularization_type == :control
            Quu_reg = Quu + res.ρ[1]*I
            Qux_reg = Qux
        end

        # Constraints
        if res isa ConstrainedIterResults
            Cx, Cu = res.Cx[k], res.Cu[k]
            Qx += Cx'*Iμ[k]*C[k] + Cx'*LAMBDA[k]
            Qu += Cu'*Iμ[k]*C[k] + Cu'*LAMBDA[k]
            Qxx += Cx'*Iμ[k]*Cx
            Quu += Cu'*Iμ[k]*Cu
            Qux += Cu'*Iμ[k]*Cx

            # again, separate regularized Quu, Qux
            Quu_reg += Cu'*Iμ[k]*Cu
            Qux_reg += Cu'*Iμ[k]*Cx
        end

        # Regularization
        if !isposdef(Hermitian(Array(Quu_reg)))  # need to wrap Array since isposdef doesn't work for static arrays
            if solver.opts.verbose
                println("regularized (normal bp)")
                println("-condition number: $(cond(Array(Quu_reg)))")
                println("Quu_reg: $Quu_reg")
            end

            # increase regularization
            regularization_update!(res,solver,:increase)

            # reset backward pass
            k = N-1
            Δv = [0.0 0.0]
            continue
        end

        # Compute gains
        K[k] = -Quu_reg\Qux_reg
        d[k] = -Quu_reg\Qu

        # Calculate cost-to-go (using unregularized Quu and Qux)
        s[k] = vec(Qx) + K[k]'*Quu*vec(d[k]) + K[k]'*vec(Qu) + Qux'*vec(d[k])
        S[k] = Qxx + K[k]'*Quu*K[k] + K[k]'*Qux + Qux'*K[k]
        S[k] = 0.5*(S[k] + S[k]')

        # calculated change is cost-to-go over entire trajectory
        Δv += [vec(d[k])'*vec(Qu) 0.5*vec(d[k])'*Quu*vec(d[k])]

        k = k - 1;
    end

    # decrease regularization after successful backward pass
    regularization_update!(res,solver,:decrease)

    return Δv
end

"""
$(SIGNATURES)
Perform a backwards pass with Cholesky Factorizations of the Cost-to-Go to
avoid ill-conditioning.
"""
function backwardpass_sqrt!(res::SolverVectorResults,solver::Solver)
    N = solver.N
    n = solver.model.n
    m = solver.model.m

    if solver.model.m != length(res.U[1])
        m += n
    end

    Q = solver.obj.Q
    R = solver.obj.R
    xf = solver.obj.xf
    Qf = solver.obj.Qf
    dt = solver.dt

    Uq = cholesky(Q).U
    Ur = cholesky(R).U

    # pull out values from results
    X = res.X; U = res.U; K = res.K; d = res.d; Su = res.S; s = res.s

    # Terminal Cost-to-go
    if isa(solver.obj, ConstrainedObjective)
        Cx = res.Cx_N
        Su[N] = cholesky(Qf + Cx'*res.IμN*Cx).U
        s[N] = Qf*(X[N] - xf) + Cx'*res.IμN*res.CN + Cx'*res.λN
    else
        Su[N] = cholesky(Qf).U
        s[N] = Qf*(X[N] - xf)
    end

    # Initialization of expected change in cost-to-go
    Δv = [0. 0.]

    k = N-1

    # Backward pass
    while k >= 1
        lx = dt*Q*(X[k] - xf)
        lu = dt*R*(U[k])
        lxx = dt*Q
        luu = dt*R

        fx, fu = res.fx[k], res.fu[k]

        Qx = lx + fx'*s[k+1]
        Qu = lu + fu'*s[k+1]

        Wxx = chol_plus(Su[k+1]*fx, cholesky(lxx).U)
        Wuu = chol_plus(Su[k+1]*fu, cholesky(luu).U)

        Qxu = (fx'*Su[k+1]')*(Su[k+1]*fu)

        # Constraints
        if isa(solver.obj, ConstrainedObjective)
            Iμ = res.Iμ; C = res.C; LAMBDA = res.LAMBDA;
            Cx, Cu = res.Cx[k], res.Cu[k]
            Iμ2 = sqrt.(Iμ[k])
            Qx += (Cx'*Iμ[k]*C[k] + Cx'*LAMBDA[k])
            Qu += (Cu'*Iμ[k]*C[k] + Cu'*LAMBDA[k])
            Qxu += Cx'*Iμ[k]*Cu

            Wxx = chol_plus(Wxx.R, Iμ2*Cx)
            Wuu = chol_plus(Wuu.R, Iμ2*Cu)
        end

        K[k] = -Wuu.R\(Array(Wuu.R')\Array(Qxu'))
        d[k] = -Wuu.R\(Wuu.R'\Qu)

        s[k] = Qx - Qxu*(Wuu.R\(Wuu.R'\Qu))

        try  # Regularization
            Su[k] = chol_minus(Wxx.R,(Array(Wuu.R'))\Array(Qxu'))
        catch ex
            error("sqrt bp not implemented")
        end

        # Expected change in cost-to-go
        Δv += [vec(Qu)'*vec(d[k]) 0.5*vec(d[k])'*Wuu.R*Wuu.R*vec(d[k])]

        k = k - 1;
    end

    return Δv
end

function backwardpass_foh!(res::SolverVectorResults,solver::Solver)
    n, m, N = get_sizes(solver)

    # Check for infeasible start
    if solver.model.m != length(res.U[1])
        m += n
    end

    dt = solver.dt

    Q = solver.obj.Q
    R = getR(solver)
    Qf = solver.obj.Qf
    xf = solver.obj.xf

    K = res.K
    b = res.b
    d = res.d

    dt = solver.dt

    X = res.X
    U = res.U

    # Initialization of expected change in cost-to-go
    Δv = [0. 0.]

    # Boundary conditions
    S = zeros(n+m,n+m)
    s = zeros(n+m)
    S[1:n,1:n] = Qf
    s[1:n] = Qf*(X[N]-xf)

    # Terminal constraints
    if res isa ConstrainedIterResults
        C = res.C; Iμ = res.Iμ; LAMBDA = res.LAMBDA
        CxN = res.Cx_N
        S[1:n,1:n] += CxN'*res.IμN*CxN
        s[1:n] += CxN'*res.IμN*res.CN + CxN'*res.λN
    end

    # Backward pass
    k = N-1
    while k >= 1
        ## Calculate the L(x,u,y,v) second order expansion
        # Unpack Jacobians, ̇x
        Ac1, Bc1 = res.Ac[k], res.Bc[k]
        Ac2, Bc2 = res.Ac[k+1], res.Bc[k+1]
        Ad, Bd, Cd = res.fx[k], res.fu[k], res.fv[k]

        xm = res.xmid[k]
        um = (U[k] + U[k+1])/2.0

        # Expansion of stage cost L(x,u,y,v) -> dL(dx,du,dy,dv)
        Lx = dt/6*Q*(X[k] - xf) + 4*dt/6*(I/2 + dt/8*Ac1)'*Q*(xm - xf)
        Lu = dt/6*R*U[k] + 4*dt/6*((dt/8*Bc1)'*Q*(xm - xf) + 0.5*R*um)
        Ly = dt/6*Q*(X[k+1] - xf) + 4*dt/6*(I/2 - dt/8*Ac2)'*Q*(xm - xf)
        Lv = dt/6*R*U[k+1] + 4*dt/6*((-dt/8*Bc2)'*Q*(xm - xf) + 0.5*R*um)

        Lxx = dt/6*Q + 4*dt/6*(I/2 + dt/8*Ac1)'*Q*(I/2 + dt/8*Ac1)
        Luu = dt/6*R + 4*dt/6*((dt/8*Bc1)'*Q*(dt/8*Bc1) + 0.5*R*0.5)
        Lyy = dt/6*Q + 4*dt/6*(I/2 - dt/8*Ac2)'*Q*(I/2 - dt/8*Ac2)
        Lvv = dt/6*R + 4*dt/6*((-dt/8*Bc2)'*Q*(-dt/8*Bc2) + 0.5*R*0.5)

        Lxu = 4*dt/6*(I/2 + dt/8*Ac1)'*Q*(dt/8*Bc1)
        Lxy = 4*dt/6*(I/2 + dt/8*Ac1)'*Q*(I/2 - dt/8*Ac2)
        Lxv = 4*dt/6*(I/2 + dt/8*Ac1)'*Q*(-dt/8*Bc2)
        Luy = 4*dt/6*(dt/8*Bc1)'*Q*(I/2 - dt/8*Ac2)
        Luv = 4*dt/6*((dt/8*Bc1)'*Q*(-dt/8*Bc2) + 0.5*R*0.5)
        Lyv = 4*dt/6*(I/2 - dt/8*Ac2)'*Q*(-dt/8*Bc2)

        # Constraints
        if res isa ConstrainedIterResults
            Cy, Cv = res.Cx[k+1], res.Cu[k+1]
            Ly += (Cy'*Iμ[k+1]*C[k+1] + Cy'*LAMBDA[k+1])
            Lv += (Cv'*Iμ[k+1]*C[k+1] + Cv'*LAMBDA[k+1])
            Lyy += Cy'*Iμ[k+1]*Cy
            Lvv += Cv'*Iμ[k+1]*Cv
            Lyv += Cy'*Iμ[k+1]*Cv
        end

        # Unpack cost-to-go P
        Sy = s[1:n]
        Sv = s[n+1:n+m]
        Syy = S[1:n,1:n]
        Svv = S[n+1:n+m,n+1:n+m]
        Syv = S[1:n,n+1:n+m]

        # Substitute in discrete dynamics (second order approximation)
        Qx = vec(Lx) + Ad'*vec(Ly) + Ad'*vec(Sy)
        Qu = vec(Lu) + Bd'*vec(Ly) + Bd'*vec(Sy)
        Qv = vec(Lv) + Cd'*vec(Ly) + Cd'*vec(Sy) + Sv

        Qxx = Lxx + Lxy*Ad + Ad'*Lxy' + Ad'*Lyy*Ad + Ad'*Syy*Ad
        Quu = Luu + Luy*Bd + Bd'*Luy' + Bd'*Lyy*Bd + Bd'*Syy*Bd
        Qvv = Lvv + Lyv'*Cd + Cd'*Lyv + Cd'*Lyy*Cd + Cd'*Syy*Cd + Cd'*Syv + Syv'*Cd + Svv
        Qxu = Lxu + Lxy*Bd + Ad'*Luy' + Ad'*Lyy*Bd + Ad'*Syy*Bd
        Qxv = Lxv + Lxy*Cd + Ad'*Lyv + Ad'*Lyy*Cd + Ad'*Syy*Cd + Ad'*Syv
        Quv = Luv + Luy*Cd + Bd'*Lyv + Bd'*Lyy*Cd + Bd'*Syy*Cd + Bd'*Syv

        # regularized terms
        if solver.opts.regularization_type == :state
            Qvv_reg = Lvv + Lyv'*Cd + Cd'*Lyv + Cd'*Lyy*Cd + Cd'*(Syy + res.ρ[1]*I)*Cd + Cd'*Syv + Syv'*Cd + Svv
            Qxv_reg = Lxv + Lxy*Cd + Ad'*Lyv + Ad'*Lyy*Cd + Ad'*(Syy + res.ρ[1]*I)*Cd + Ad'*Syv
            Quv_reg = Luv + Luy*Cd + Bd'*Lyv + Bd'*Lyy*Cd + Bd'*(Syy + res.ρ[1]*I)*Cd + Bd'*Syv
        elseif solver.opts.regularization_type == :control
            Qvv_reg = Qvv + res.ρ[1]*I
            Qxv_reg = Qxv
            Quv_reg = Quv
        end

        if !isposdef(Hermitian(Array(Qvv_reg)))
            if solver.opts.verbose
                println("regularized (foh bp)\n not implemented properly")
            end

            regularization_update!(res,solver,:increase)

            k = N-1
            Δv = [0. 0.]

            # Reset BCs
            S = zeros(n+m,n+m)
            s = zeros(n+m)
            S[1:n,1:n] = Qf
            s[1:n] = Qf*(X[N]-xf)

            # Terminal constraints
            if res isa ConstrainedIterResults
                C = res.C; Iμ = res.Iμ; LAMBDA = res.LAMBDA
                CxN = res.Cx_N
                S[1:n,1:n] += CxN'*res.IμN*CxN
                s[1:n] += CxN'*res.IμN*res.CN + CxN'*res.λN
            end
            ############
            continue
        end

        # calculate gains
        K[k+1] = -Qvv_reg\Qxv_reg'
        b[k+1] = -Qvv_reg\Quv_reg'
        d[k+1] = -Qvv_reg\vec(Qv)

        # calculate optimized values
        Qx_ = vec(Qx) + K[k+1]'*vec(Qv) + Qxv*vec(d[k+1]) + K[k+1]'Qvv*d[k+1]
        Qu_ = vec(Qu) + b[k+1]'*vec(Qv) + Quv*vec(d[k+1]) + b[k+1]'*Qvv*d[k+1]
        Qxx_ = Qxx + Qxv*K[k+1] + K[k+1]'*Qxv' + K[k+1]'*Qvv*K[k+1]
        Quu_ = Quu + Quv*b[k+1] + b[k+1]'*Quv' + b[k+1]'*Qvv*b[k+1]
        Qxu_ = Qxu + K[k+1]'*Quv' + Qxv*b[k+1] + K[k+1]'*Qvv*b[k+1]

        # cache (approximate) cost-to-go at timestep k
        s[1:n] = Qx_
        s[n+1:n+m] = Qu_
        S[1:n,1:n] = Qxx_
        S[n+1:n+m,n+1:n+m] = Quu_
        S[1:n,n+1:n+m] = Qxu_
        S[n+1:n+m,1:n] = Qxu_'

        # line search terms
        Δv += [vec(Qv)'*vec(d[k+1]) 0.5*vec(d[k+1])'*Qvv*vec(d[k+1])]

        # at last time step, optimize over final control
        if k == 1
            if res isa ConstrainedIterResults
                Cx, Cu = res.Cx[k], res.Cu[k]
                Qx_ += (Cx'*Iμ[k]*C[k] + Cx'*LAMBDA[k])
                Qu_ += (Cu'*Iμ[k]*C[k] + Cu'*LAMBDA[k])
                Qxx_ += Cx'*Iμ[k]*Cx
                Quu_ += Cu'*Iμ[k]*Cu
                Qxu_ += Cx'*Iμ[k]*Cu
            end

            # regularize Quu_
            Quu__reg = Quu_ + res.ρ[1]*I

            if !isposdef(Array(Hermitian(Quu__reg)))
                if solver.opts.verbose
                    println("regularized (foh bp)")
                    println("part 2")
                end

                regularization_update!(res,solver,:increase)
                k = N-1
                Δv = [0. 0.]

                ## Reset BCs ##
                S = zeros(n+m,n+m)
                s = zeros(n+m)
                S[1:n,1:n] = Qf
                s[1:n] = Qf*(X[N]-xf)

                # Terminal constraints
                if res isa ConstrainedIterResults
                    C = res.C; Iμ = res.Iμ; LAMBDA = res.LAMBDA
                    CxN = res.Cx_N
                    S[1:n,1:n] += CxN'*res.IμN*CxN
                    s[1:n] += CxN'*res.IμN*res.CN + CxN'*res.λN
                end
                ################
                continue
            end

            K[1] = -Array(Quu__reg)\Array(Qxu_')
            b[1] = zeros(m,m)
            d[1] = -Array(Quu__reg)\vec(Qu_)

            res.s[1] = Qx_ + Qxu_*vec(d[1])

            Δv += [vec(Qu_)'*vec(d[1]) 0.5*vec(d[1])'*Quu_*vec(d[1])]

        end

        k = k - 1;
    end

    regularization_update!(res,solver,:decrease)
    return Δv
end

"""
$(SIGNATURES)
Perform the operation sqrt(A-B), where A and B are Symmetric Matrices
"""
function chol_minus(A,B::Matrix)
    AmB = Cholesky(A,:U,0)
    for i = 1:size(B,1)
        lowrankdowndate!(AmB,B[i,:])
    end
    U = AmB.U
end

function chol_plus(A,B)
    n1,m = size(A)
    n2 = size(B,1)
    P = zeros(n1+n2,m)
    P[1:n1,:] = A
    P[n1+1:end,:] = B
    qr(P)
end

"""
$(SIGNATURES)
Propagate dynamics with a line search (in-place)
"""
function forwardpass!(res::SolverIterResults, solver::Solver, Δv::Array{Float64,2})
    # Pull out values from results
    X = res.X
    U = res.U
    K = res.K
    d = res.d
    X_ = res.X_
    U_ = res.U_

    # Compute original cost
    update_constraints!(res,solver,X,U)

    J_prev = cost(solver, res, X, U)

    J = Inf
    alpha = 1.0
    iter = 0
    z = 0.

    while z ≤ solver.opts.c1 || z > solver.opts.c2

        # Check that maximum number of line search decrements has not occured
        if iter > solver.opts.iterations_linesearch
            # set trajectories to original trajectory
            X_ .= X
            U_ .= U

            update_constraints!(res,solver,X_,U_)
            J = copy(J_prev)
            z = 0.

            if solver.opts.verbose
                @logmsg InnerLoop "Max iterations (forward pass) -No improvement made"
            end
            alpha = 0.0
            regularization_update!(res,solver,:increase) # increase regularization
            break
        end

        # Otherwise, rollout a new trajectory for current alpha
        flag = rollout!(res,solver,alpha)

        # Check if rollout completed
        if ~flag
            # Reduce step size if rollout returns non-finite values (NaN or Inf)
            if solver.opts.verbose
                @debug "Non-finite values in rollout"
            end
            iter += 1
            alpha /= 2.0
            continue
        end

        # Calcuate cost
        update_constraints!(res,solver,X_,U_)
        J = cost(solver, res, X_, U_)
        z = (J_prev - J)/(-alpha*(Δv[1] + alpha*Δv[2]))

        alpha /= 2.0

        iter += 1
    end

    if solver.opts.verbose
        alpha *= 2.0 # we decremented since the last implemenation of alpha so we need to return to previous value
        if res isa ConstrainedIterResults
            # @logmsg :scost value=cost(solver,res,res.X,res.U,true)
            @logmsg InnerLoop :c_max value=max_violation(res)
        end
        @logmsg InnerLoop :expected value=-(alpha)*(Δv[1] + (alpha)*Δv[2])
        @logmsg InnerLoop :actual value=J_prev-J
        @logmsg InnerLoop :z value=z
        @logmsg InnerLoop :α value=alpha
    end

    # if alpha > 0.0
    #     regularization_update!(res,solver,false)
    # end

    return J
end

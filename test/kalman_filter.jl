path = dirname(@__FILE__)

# Initialize arguments to function
h5 = h5open("$path/reference/kalman_filter_args.h5", "r")
for arg in ["data", "TTT", "RRR", "CCC", "QQ", "ZZ", "DD", "EE", "z0", "P0"]
    eval(parse("$arg = read(h5, \"$arg\")"))
end
close(h5)

# Method with all arguments provided
out = kalman_filter(data, TTT, RRR, CCC, QQ, ZZ, DD, EE, z0, P0)

h5open("$path/reference/kalman_filter_out.h5", "r") do h5
    # @test read(h5, "log_likelihood") ≈ out[1] # TODO: compute this after
    @test read(h5, "log_likelihood") ≈ log_likelihood(out)
    @test read(h5, "pred")           ≈ out.pred
    @test read(h5, "vpred")          ≈ out.vpred
    @test read(h5, "filt")           ≈ out.filt
    @test read(h5, "vfilt")          ≈ out.vfilt
    @test read(h5, "yprederror")     ≈ out.yprederror
    @test read(h5, "ystdprederror")  ≈ out.ystdprederror
    # @test read(h5, "rmse")           ≈ out[10] # TODO: compute this after
    @test read(h5, "rmse")           ≈ rmse(out)
    # @test read(h5, "rmsd")           ≈ out[11] # TODO: compute this after
    @test read(h5, "rmsd")           ≈ rmsd(out)
    @test z0                         ≈ out.z0
    @test P0                         ≈ out.P0
    @test read(h5, "marginal_loglh") ≈ out.marginal_loglh
end

# Method with initial conditions omitted
out = kalman_filter(data, TTT, RRR, CCC, QQ, ZZ, DD, EE)

# Pend, vpred, and vfilt matrix entries are especially large, averaging 1e5, so
# we allow greater ϵ
h5open("$path/reference/kalman_filter_out.h5", "r") do h5
    # @test read(h5, "log_likelihood") ≈ out[1] # TODO: compute this after
    @test read(h5, "log_likelihood") ≈ log_likelihood(out)
    @test read(h5, "pred")           ≈ out.pred
    @test read(h5, "vpred")          ≈ out.vpred
    @test read(h5, "filt")           ≈ out.filt
    @test read(h5, "vfilt")          ≈ out.vfilt
    @test read(h5, "yprederror")     ≈ out.yprederror
    @test read(h5, "ystdprederror")  ≈ out.ystdprederror
    # @test read(h5, "rmse")           ≈ out[10] # TODO: compute this after
    @test read(h5, "rmse")           ≈ rmse(out)
    # @test read(h5, "rmsd")           ≈ out[11] # TODO: compute this after
    @test read(h5, "rmsd")           ≈ rmsd(out)
    @test z0                         ≈ out.z0
    @test P0                         ≈ out.P0
    @test read(h5, "marginal_loglh") ≈ out.marginal_loglh
end


nothing

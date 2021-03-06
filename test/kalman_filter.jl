path = dirname(@__FILE__)

# Initialize arguments to function
file = h5open("$path/reference/kalman_filter_args.h5", "r")
y = read(file, "data")
T, R, C    = read(file, "TTT"), read(file, "RRR"), read(file, "CCC")
Q, Z, D, E = read(file, "QQ"), read(file, "ZZ"), read(file, "DD"), read(file, "EE")
s_0, P_0   = read(file, "z0"), read(file, "P0")
close(file)

# Method with all arguments provided
out = kalman_filter(y, T, R, C, Q, Z, D, E, s_0, P_0)

h5open("$path/reference/kalman_filter_out.h5", "r") do h5
    @test read(h5, "log_likelihood") ≈ sum(out[1])
    @test read(h5, "marginal_loglh") ≈ out[1]
    @test read(h5, "pred")           ≈ out[2]
    @test read(h5, "vpred")          ≈ out[3]
    @test read(h5, "filt")           ≈ out[4]
    @test read(h5, "vfilt")          ≈ out[5]
    @test s_0                        ≈ out[6]
    @test P_0                        ≈ out[7]
end

# Method with initial conditions omitted
out = kalman_filter(y, T, R, C, Q, Z, D, E)

h5open("$path/reference/kalman_filter_out.h5", "r") do h5
    @test read(h5, "log_likelihood") ≈ sum(out[1])
    @test read(h5, "marginal_loglh") ≈ out[1]
    @test read(h5, "pred")           ≈ out[2]
    @test read(h5, "vpred")          ≈ out[3]
    @test read(h5, "filt")           ≈ out[4]
    @test read(h5, "vfilt")          ≈ out[5]
    @test s_0                        ≈ out[6]
    @test P_0                        ≈ out[7]
end


nothing

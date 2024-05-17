# using StaticArrays: @SVector
#@everywhere ENV["JULIA_DEBUG"] = "Dagger"
@everywhere function rand_finite(T=Float64)
    x = rand(T)
    if x < 0.1
        return Dagger.finish_stream(x)
    end
    return x
end
function catch_interrupt(f)
    try
        f()
    catch err
        if err isa Dagger.ThunkFailedException && err.ex isa InterruptException
            return
        elseif err isa Dagger.Sch.SchedulingException
            return
        end
        rethrow(err)
    end
end
function test_finishes(f, message::String; ignore_timeout=false)
    t = @eval Threads.@spawn @testset $message catch_interrupt($f)
    if timedwait(()->istaskdone(t), 30) == :timed_out
        if !ignore_timeout
            @warn "Testing task timed out: $message"
        end
        Dagger.cancel!(;halt_sch=true, force=true)
        fetch(Dagger.@spawn 1+1)
        return false
    end
    return true
end
function update_vector!(v)
    # We hereby assume that v is a vector that is either static or pre-allocated
    # ! is for in-place modification
    for i in 1:length(v)
        v[i] += 1
    end
    return nothing
end

@testset "Basics" begin
    @test !test_finishes("Single task running forever"; ignore_timeout=true) do
        local x
        Dagger.spawn_streaming() do
            x = Dagger.spawn() do
                y = rand()
                sleep(1)
                return y
            end
        end
        fetch(x)
    end

    @test test_finishes("Single task") do
        local x
        Dagger.spawn_streaming() do
            x = Dagger.@spawn rand_finite()
        end
        @test fetch(x) === nothing
    end


    trd_idxs = [1 1 1 1; 1 2 3 4; 1 1 1 1; 1 2 3 4]
    wkr_idxs = [1 1 1 1; 1 1 1 1; 1 2 3 4; 1 2 3 4]
    addprocs(4; exeflags="--project=$(joinpath(@__DIR__, ".."))")
    @everywhere using Dagger
    @everywhere using Distributed
for T in (Float64, BigFloat)
    for idx in 1:4
        # Add workers, as we are going to loop over different combinations

        scp1 = Dagger.scope(worker = wkr_idxs[idx, 1], thread = trd_idxs[idx, 1])
        scp2 = Dagger.scope(worker = wkr_idxs[idx, 2], thread = trd_idxs[idx, 2])
        scp3 = Dagger.scope(worker = wkr_idxs[idx, 3], thread = trd_idxs[idx, 3])
        scp4 = Dagger.scope(worker = wkr_idxs[idx, 4], thread = trd_idxs[idx, 4])
        println(string(wkr_idxs[idx, 1]) * " " * string(trd_idxs[idx, 1]) )
        println(join([scp1, scp2, scp3, scp4], ", "))
        @test test_finishes("Two tasks (sequential)") do
            local x, y
            Dagger.spawn_streaming() do
                x = Dagger.@spawn scope=scp1 rand_finite(T)
                y = Dagger.@spawn scope=scp2 x+1
            end
            @test fetch(x) === nothing
            @test_throws Dagger.ThunkFailedException fetch(y)
        end

        @test test_finishes("Two tasks (parallel)") do
            local x, y
            Dagger.spawn_streaming() do
                x = Dagger.@spawn scope=scp1 rand_finite()
                y = Dagger.@spawn scope=scp2 rand_finite()
            end
            @test fetch(x) === nothing
            @test fetch(y) === nothing
        end
"""        # TODO: Three tasks (2 -> 1)
        @test test_finishes("Three tasks (2 -> 1)") do
            local x,y,z
            Dagger.spawn_streaming() do
                x = Dagger.@spawn scope=scp1 rand_finite()
                y = Dagger.@spawn scope=scp2 rand_finite()
                z = Dagger.@spawn scope=scp3 ( x + y )
            end
            @test fetch(x) === nothing
            @test fetch(y) === nothing
            @test_throws Dagger.ThunkFailedException fetch(z)
        end
        # TODO: Three tasks (1 -> 2)
        @test test_finishes("Three tasks (1 -> 2)") do
            local x,y,z
            Dagger.spawn_streaming() do
                x = Dagger.@spawn scope=scp1 rand_finite()
                y = Dagger.@spawn scope=scp2 ( x * 2 )
                z = Dagger.@spawn scope=scp3 ( x + 2 )
            end
            @test fetch(x) === nothing
            @test_throws Dagger.ThunkFailedException fetch(y)
            @test_throws Dagger.ThunkFailedException fetch(z)
        end
        # TODO: Four tasks (diamond)
        @test test_finishes("Four tasks (diamond)") do
            local x, y, z, w
            Dagger.spawn_streaming() do
                x = Dagger.@spawn scope=scp1 rand_finite()
                y = Dagger.@spawn scope=scp2 ( x * 2 )
                z = Dagger.@spawn scope=scp3 ( x + 2 )
                w = Dagger.@spawn scope=scp4 ( y * z - 3 )
            end
            @test fetch(x) === nothing
            @test_throws Dagger.ThunkFailedException fetch(y)
            @test_throws Dagger.ThunkFailedException fetch(z)
            @test_throws Dagger.ThunkFailedException fetch(w)
        end"""
    end
    rmprocs(workers())

    @test test_finishes("Without result") do
        local x
        Dagger.spawn_streaming() do
            x = Dagger.spawn() do
                x = rand()
                if x < 0.1
                    return Dagger.finish_stream(x)
                end
                return x
            end
        end
        @test fetch(x) === nothing
    end
    @test test_finishes("With result") do
        local x
        Dagger.spawn_streaming() do
            x = Dagger.spawn() do
               x = rand()
                if x < 0.1
                    return Dagger.finish_stream(x; result=123)
                end
                return x
            end
        end
        @test fetch(x) == 123
    end

   #  TODO: Custom stream buffers/buffer amounts
    @test test_finishes("Custom stream buffer amounts") do
        # local x
        Dagger.spawn_streaming() do
            Dagger.with_options(;stream_input_buffer_amount=2,
			        stream_output_buffer_amount=4,
				 stream_input_buffer=Dagger.DropBuffer) do
                x = Dagger.@spawn rand_finite()
            end
        end
    end


# TODO: Different stream element types (immutable and mutable)
#    @test test_finishes("Different Stream Element Types") do
#    local x, y
#
#    Dagger.spawn_streaming() do
#        # Immutable data type, e.g. a tuple
#        x = Dagger.spawn do
#            x = ("one", 2.0, 3)
#            return x
#        end
#        # Mutable data type, e.g. an array
#        y = Dagger.spawn do
#            y = [1, 2, 3]
#        end
#     end
#     # Check data integrity
#     @test typeof(fetch(x)) === Tuple
#        @test fetch(x) == ("one", 2.0, 3)
#        @test fetch(y) == [1, 2, 3]
#        @test typeof(fetch(y)) == Array

# TODO: Zero-allocation examples
#    v = @SVector [0,1,2]
#    allocations = @allocated update_vector!(v)
#    @test allocations == 0
#    @test v == @SVector [1,2,3]"""
end
# FIXME: Streaming across threads

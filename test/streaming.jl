# using StaticArrays: @SVector
@everywhere ENV["JULIA_DEBUG"] = "Dagger"
@everywhere function rand_finite()
    x = rand()
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
    if timedwait(()->istaskdone(t), 5) == :timed_out
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
    @test test_finishes("Single task") do
        local x
        Dagger.spawn_streaming() do
            x = Dagger.@spawn rand_finite()
        end
        @test fetch(x) === nothing
    end

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

    trd_idxs = [1 1 1 1; 1 2 3 4; 1 1 1 1; 1 2 3 4]
    wkr_idxs = [1 1 1 1; 1 1 1 1; 1 2 3 4; 1 2 3 4]
    addprocs(4)
    @everywhere using Dagger
    @everywhere using Distributed
    for idx in 1:1
        # Add workers, as we are going to loop over different combinations

        scp1 = Dagger.scope(worker = wkr_idxs[idx, 1], thread = trd_idxs[idx, 1])
        scp2 = Dagger.scope(worker = wkr_idxs[idx, 2], thread = trd_idxs[idx, 2])
        scp3 = Dagger.scope(worker = wkr_idxs[idx, 3], thread = trd_idxs[idx, 3])
        scp4 = Dagger.scope(worker = wkr_idxs[idx, 4], thread = trd_idxs[idx, 4])
        println(string(wkr_idxs[idx, 1]) * " " * string(trd_idxs[idx, 1]) )
        println(scp1, scp2, scp3, scp4)
        @test test_finishes("Two tasks (sequential)") do
            local x, y
            Dagger.spawn_streaming() do
                x = Dagger.@spawn scope=scp1 rand_finite()
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
    # TODO: With pass-through/Without result
#    @test test_finishes() do
#
#    end
    # TODO: With pass-through/With result
#    @test test_finishes() do
#
#    end
    # TODO: Without pass-through/Without result
    # Not sure how this is different from rand finite, and specifically from the single task test
    @test test_finishes("Without pass-through/Without result") do
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
    @test test_finishes("Without pass-through/With result") do
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
# TODO: Custom stream buffers/buffer amounts
#    @test test_finishes("Custom stream buffer amounts") do
#        # local x
#    ## actually unsure on how to do this
#    end
# TODO: Cross-worker streaming
"""    @test test_finishes("Cross-worker Streaming") do
        addprocs(2)
        local x, y

        Dagger.spawn_streaming() do
            x = Dagger.@spawn scope=Dagger.scope(worker=2) rand_finite()
            y = Dagger.@spawn scope=Dagger.scope(worker=3) fetch((x) .* 2)
        end
        @test fetch(x) === nothing
        @test_throws Dagger.ThunkFailedException fetch(y)
        rmprocs(workers()[1:2])
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

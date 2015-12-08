export Context

type Context
    dist_memory_procs::Vector
end

Context() = Context(workers())

function chunk_targets(ctx::Context, node)
     ctx.dist_memory_procs # For now, the targets are all the available workers
end

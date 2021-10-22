module Events

import ..Dagger
import ..Dagger: Event, Chunk
import ..Dagger: init_similar

import ..Tables

"""
    CoreMetrics

Tracks the timestamp, category, and kind of the `Event` object generated by log
events.
"""
struct CoreMetrics end

(::CoreMetrics)(ev::Event{T}) where T =
    (;timestamp=ev.timestamp,
      category=ev.category,
      kind=T)

"""
    IDMetrics

Tracks the ID of `Event` objects generated by log events.
"""
struct IDMetrics end

(::IDMetrics)(ev::Event{T}) where T = ev.id

"""
    TimelineMetrics

Tracks the timeline of `Event` objects generated by log events.
"""
struct TimelineMetrics end

(::TimelineMetrics)(ev::Event{T}) where T = ev.timeline

"""
    FullMetrics

Tracks the full `Event` object generated by log events.
"""
struct FullMetrics end

(::FullMetrics)(ev) = ev

"""
    BytesAllocd

Tracks memory allocated for `Chunk`s.
"""
mutable struct BytesAllocd
    allocd::Int
end
BytesAllocd() = BytesAllocd(0)
init_similar(::BytesAllocd) = BytesAllocd()

function (ba::BytesAllocd)(ev::Event{:start})
    if ev.category in (:move, :evict) && ev.timeline.data isa Chunk
        sz = Int(ev.timeline.data.handle.size)
        if ev.category == :move && !haskey(Dagger.Sch.CHUNK_CACHE, ev.timeline.data)
            ba.allocd += sz
        elseif ev.category == :evict && haskey(Dagger.Sch.CHUNK_CACHE, ev.timeline.data)
            ba.allocd -= sz
        end
    end
    ba.allocd
end
(ba::BytesAllocd)(ev::Event{:finish}) = ba.allocd

"""
    CPULoadAverages

Monitors the CPU load averages.
"""
struct CPULoadAverages end

(::CPULoadAverages)(ev::Event) = Sys.loadavg()[1]

"""
    MemoryFree

Monitors the percentage of free system memory.
"""
struct MemoryFree end

(::MemoryFree)(ev::Event) = Sys.free_memory() / Sys.total_memory()

"""
    EventSaturation

Tracks the compute saturation (running tasks) per-processor.
"""
mutable struct EventSaturation
    saturation::Dict{Symbol,Int}
end
EventSaturation() = EventSaturation(Dict{Symbol,Int}())
init_similar(::EventSaturation) = EventSaturation()

function (es::EventSaturation)(ev::Event{:start})
    old = get(es.saturation, ev.category, 0)
    es.saturation[ev.category] = old + 1
    NamedTuple(filter(x->x[2]>0, es.saturation))
end
function (es::EventSaturation)(ev::Event{:finish})
    old = get(es.saturation, ev.category, 0)
    es.saturation[ev.category] = old - 1
    NamedTuple(filter(x->x[2]>0, es.saturation))
end

"""
    WorkerSaturation

Tracks the compute saturation (running tasks).
"""
mutable struct WorkerSaturation
    saturation::Int
end
WorkerSaturation() = WorkerSaturation(0)
init_similar(::WorkerSaturation) = WorkerSaturation()

function (ws::WorkerSaturation)(ev::Event{:start})
    if ev.category == :compute
        ws.saturation += 1
    end
    ws.saturation
end
function (ws::WorkerSaturation)(ev::Event{:finish})
    if ev.category == :compute
        ws.saturation -= 1
    end
    ws.saturation
end

"""
    ProcessorSaturation

Tracks the compute saturation (running tasks) per-processor.
"""
mutable struct ProcessorSaturation
    saturation::Dict{Dagger.Processor,Int}
end
ProcessorSaturation() = ProcessorSaturation(Dict{Dagger.Processor,Int}())
init_similar(::ProcessorSaturation) = ProcessorSaturation()

function (ps::ProcessorSaturation)(ev::Event{:start})
    if ev.category == :compute
        proc = ev.timeline.to_proc
        old = get(ps.saturation, proc, 0)
        ps.saturation[proc] = old + 1
    end
    filter(x->x[2]>0, ps.saturation)
end
function (ps::ProcessorSaturation)(ev::Event{:finish})
    if ev.category == :compute
        proc = ev.timeline.to_proc
        old = get(ps.saturation, proc, 0)
        ps.saturation[proc] = old - 1
    end
    filter(x->x[2]>0, ps.saturation)
end

"""
    LogWindow

Aggregator that prunes events to within a given time window.
"""
mutable struct LogWindow
    window_length::UInt64
    core_name::Symbol
    creation_handlers::Vector{Any}
    deletion_handlers::Vector{Any}
end
LogWindow(window_length, core_name) = LogWindow(window_length, core_name, [], [])

function (lw::LogWindow)(logs::Dict)
    core_log = logs[lw.core_name]

    # Inform creation hooks
    if length(core_log) > 0
        log = Dict{Symbol,Any}()
        for key in keys(logs)
            log[key] = last(logs[key])
        end
        for obj in lw.creation_handlers
            creation_hook(obj, log)
        end
    end

    # Find entries outside the window
    window_start = time_ns() - lw.window_length
    idx = something(findfirst(ev->ev.timestamp >= window_start, core_log),
                    length(core_log))

    # Return if all events are in the window
    if length(core_log) == 0 || (core_log[1].timestamp >= window_start)
        return
    end

    # Inform deletion hooks
    for obj in lw.deletion_handlers
        deletion_hook(obj, idx)
    end

    # Remove entries outside the window
    for name in keys(logs)
        deleteat!(logs[name], 1:idx)
    end
end

creation_hook(x, log) = nothing
deletion_hook(x, idx) = nothing

"""
    TableStorage

LogWindow-compatible aggregator which stores logs in a Tables.jl-compatible sink.
"""
struct TableStorage{T}
    sink::T
    function TableStorage(sink::T) where T
        @assert Tables.istable(sink)
        new{T}(sink)
    end
end
init_similar(ts::TableStorage) = TableStorage(similar(ts.sink, 0))
function creation_hook(ts::TableStorage, log)
    try
        push!(ts.sink, NamedTuple(log))
    catch err
        rethrow(err)
    end
end
function Base.getindex(ts::TableStorage, ts_range::UnitRange)
    ts_low, ts_high = ts_range.start, ts_range.stop
    return filter(row->ts_low <= row.core.timestamp <= ts_high,
                  Tables.rows(ts.sink)) |> Tables.materializer(ts.sink)
end

end # module Events

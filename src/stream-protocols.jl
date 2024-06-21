struct Protocol
    ip::IPAddr
    port::Integer
end
struct TCP
    protocol::Protocol
    TCP(ip::IPAddr, port::Integer) = new(Protocol(ip,port))
end
struct UDP
    protocol::Protocol
    UDP(ip::IPAddr, port::Integer) = new(Protocol(ip,port))
end
struct NATS
    protocol::Protocol
    topic::String
    NATS(ip::IPAddr, topic::String) = new(Protocol(ip, 4222), topic)
    NATS(ip::IPAddr, port::Integer, topic::String) = new(Protocol(ip, port), topic)
end
struct MQTT
    protocol::Protocol
    topic::String
    MQTT(ip::IPAddr, topic::String) = new(Protocol(ip, 1883), topic)
    MQTT(ip::IPAddr, port::Integer, topic::String) = new(Protocol(ip, port), topic)
end
struct RemoteFetcher end
function _load_val_from_buffer!(buffer, T)
    values = T[]
    while !isempty(buffer)
        value = take!(buffer)::T
        push!(values, value)
    end
    return values
end
# UDP dispatch
function stream_push_values!(udp::UDP, T, store, buffer, id::UInt)
    values = _load_val_from_buffer!(buffer, T)
    udpsock = UDPSocket()
    send(udpsock, udp.protocol.ip, udp.protocol.port, values)
    close(udpsock)
end
function stream_pull_values!(udp::UDP, T, store_ref::Chunk{Store_remote}, buffer::Blocal, id::UInt) where {Store_remote, Blocal}
    udpsock = UDPSocket
    bind(udpsock, udp.protocol.ip, udp.protocol.port)

    values = T[]
    values = recvfrom(udpsock)
    data = reinterpret(T, data)

    for value in values
        put!(buffer, value)
    end
end
# TCP dispatch
function stream_push_values!(tcp::TCP, T, store, buffer, id::UInt)
    values = _load_val_from_buffer!(buffer, T)
    @label push_values_TCP
    try
        connection = connect(tcp.protocol.ip, tcp.protocol.port)
    catch e
        if isa(e, Base.IOError)
            println("Failed to connect to $(tcp.protocol.ip):$(tcp.protocol.port) for IOError")
        elseif isa(e, Base.UVError)
            println("Failed to connect to $(tcp.protocol.ip):$(tcp.protocol.port) for UVError")
        end
        connection = nothing
    end
    if connection === nothing
        @goto push_values_TCP
    end
    write(connection, length(values))
    write(connection, values)
    close(connection)
end
# TCP dispatch
function stream_pull_values!(tcp::TCP, T, store_ref::Chunk{Store_remote}, buffer::Blocal, id::UInt) where {Store_remote, Blocal}
    @label pull_values_TCP
    try
        server = listen(tcp.protocol.ip, tcp.protocol.port)
        connection = accept(server)
    catch e
        if isa(e, Base.IOError)
            println("Failed to connect to $(tcp.protocol.ip):$(tcp.protocol.port) for IOError")
        elseif isa(e, Base.UVError)
            println("Failed to connect to $(tcp.protocol.ip):$(tcp.protocol.port) for UVError")
        end
        connection = nothing
    end

    if connection === nothing
        sleep(5)
        @goto pull_values_TCP
    end

    length = read(connection, sizeof(T))
    length = reinterpret(UInt64, length)[1]
    data = read(connection, length * sizeof(T))
    values = reinterpret(T, data)

    for value in values
        put!(buffer, value)
    end
end
# NATS dispatch
function stream_push_values!(nats::NATS, T, store, buffer, id::UInt)
    values = _load_val_from_buffer!(buffer, T)
    @label push_values_NATS
    try
        nc = NATS.connect("nats://$(nats.protocol.ip):$(nats.protocol.port)")
    catch e
        println("Failed connecting to NATS at $(nats.protocol.ip):$(nats.protocol.port).")
        nc = nothing
    end

    if nc === nothing
        sleep(5)
        @goto push_values_NATS
    end

    iob = IOBuffer()
    write(iob, length(values))
    write(iob, values)
    data = String(take!(iob))
    publish(nc, nats.topic, data)
end
function stream_pull_values!(nats::NATS, T, store_ref::Chunk{Store_remote}, buffer::Blocal, id::UInt) where {Store_remote, Blocal}
    @label pull_values_NATS
    try
        nc = NATS.connect("nats://$(nats.protocol.ip):$(nats.protocol.port)")
    catch e
        println("Failed connecting to NATS at $(nats.protocol.ip):$(nats.protocol.port).")
        nc = nothing
    end

    if nc === nothing
        sleep(5)
        @goto pull_values_NATS
    end

    function msg_handler(msg, T, buffer::Blocal)
        data = Vector{UInt8}(msg.payload)
        iob = IOBuffer(data)
        length = read(buf, Int)

        value_data = read(iob, sizeof(T) * length)
        values = reinterpret(T, value_data)

        for value in values
            put!(buffer, value)
        end
    end

    sub = subscribe(msg_handler, nc, nats.topic)
end
# MQTT dispatch
function stream_push_values!(mqtt::MQTT, T, store, buffer, id::UInt)
    values = _load_val_from_buffer!(buffer, T)
    @label push_values_MQTT
    try
        client = Mosquitto.Client(mqtt.protocol.ip, mqtt.protocol.port)
    catch e
        println("Failed connecting to MQTT Broker at $(mqtt.protocol.ip):$(mqtt.protocol.port).")
        client = nothing
    end
    if client === nothing
        sleep(5)
        @goto push_values_MQTT
    end
    data = reinterpret(UInt8, values)
    publish(client, mqtt.topic, data; retain=true)
end
function stream_pull_values!(mqtt::MQTT, T, store_ref::Chunk{Store_remote}, buffer::Blocal, id::UInt) where {Store_remote, Blocal}
    @label pull_values_MQTT
    try
        client = Mosquitto.Client(mqtt.protocol.ip, mqtt.protocol.port)
    catch e
        println("Failed connecting to MQTT Broker at $(mqtt.protocol.ip):$(mqtt.protocol.port).")
        client = nothing
    end
    if client === nothing
        sleep(5)
        @goto pull_values_MQTT
    end
    subscribe(client, mqtt.topic)

    Mosquitto.loop(client; timeout=500, ntimes=10)
    msg_channel = get_messages_channel(client)

    while !isempty(msg_channel)
        msg = take!(msg_channel)
        data = reinterpret(T, msg.payload)
        for value in data
            put!(buffer,data)
        end
    end
end
function stream_push_values!(::Type{RemoteFetcher}, T, store, buffer, id::UInt)
end
function stream_fetch_values!(::Type{RemoteFetcher}, T, store_ref::Chunk{Store_remote}, buffer::Blocal, id::UInt) where {Store_remote, Blocal}
    thunk_id = STREAM_THUNK_ID[]
    @dagdebug thunk_id :stream "fetching values"
    @label fetch_values
    # FIXME: Pass buffer free space
    # TODO: It would be ideal if we could wait on store.lock, but get unlocked during migration
    values = MemPool.access_ref(store_ref.handle, id, T, Store_remote, thunk_id) do store, id, T, Store_remote, thunk_id
        if !isopen(store)
            throw(InvalidStateException("Stream is closed", :closed))
        end
        @dagdebug thunk_id :stream "trying to fetch values at $(myid())"
        store::Store_remote
        in_store = store
        STREAM_THUNK_ID[] = thunk_id
        values = T[]
        while !isempty(store, id)
            value = take!(store, id)::T
            push!(values, value)
        end
        return values
    end::Vector{T}
    if isempty(values)
        sleep(0.5)
        @goto fetch_values
    end

    @dagdebug thunk_id :stream "fetched $(length(values)) values"
    for value in values
        put!(buffer, value)
    end
end

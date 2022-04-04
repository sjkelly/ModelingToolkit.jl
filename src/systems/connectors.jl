get_connection_type(s) = getmetadata(unwrap(s), VariableConnectType, Equality)

function with_connector_type(expr)
    @assert expr isa Expr && (expr.head == :function || (expr.head == :(=) &&
                                       expr.args[1] isa Expr &&
                                       expr.args[1].head == :call))

    sig = expr.args[1]
    body = expr.args[2]

    fname = sig.args[1]
    args = sig.args[2:end]

    quote
        function $fname($(args...))
            function f()
                $body
            end
            res = f()
            $isdefined(res, :connector_type) && $getfield(res, :connector_type) === nothing ? $Setfield.@set!(res.connector_type = $connector_type(res)) : res
        end
    end
end

macro connector(expr)
    esc(with_connector_type(expr))
end

abstract type AbstractConnectorType end
struct StreamConnector <: AbstractConnectorType end
struct RegularConnector <: AbstractConnectorType end

function connector_type(sys::AbstractSystem)
    sts = get_states(sys)
    #TODO: check the criteria for stream connectors
    n_stream = 0
    n_flow = 0
    for s in sts
        vtype = get_connection_type(s)
        if vtype === Stream
            isarray(s) && error("Array stream variables are not supported. Got $s.")
            n_stream += 1
        end
        vtype === Flow && (n_flow += 1)
    end
    (n_stream > 0 && n_flow > 1) && error("There are multiple flow variables in $(nameof(sys))!")
    n_stream > 0 ? StreamConnector() : RegularConnector()
end

Base.@kwdef struct Connection
    inners = nothing
    outers = nothing
end

# everything is inner by default until we expand the connections
Connection(syss) = Connection(inners=syss)
get_systems(c::Connection) = c.inners
function Base.in(e::Symbol, c::Connection)
    (c.inners !== nothing && any(k->nameof(k) === e, c.inners)) ||
    (c.outers !== nothing && any(k->nameof(k) === e, c.outers))
end

function renamespace(sym::Symbol, connection::Connection)
    inners = connection.inners === nothing ? [] : renamespace.(sym, connection.inners)
    if connection.outers !== nothing
        for o in connection.outers
            push!(inners, renamespace(sym, o))
        end
    end
    Connection(;inners=inners)
end

const EMPTY_VEC = []

function Base.show(io::IO, ::MIME"text/plain", c::Connection)
    # It is a bit unfortunate that the display of an array of `Equation`s won't
    # call this.
    @unpack outers, inners = c
    if outers === nothing && inners === nothing
        print(io, "<Connection>")
    else
        syss = Iterators.flatten((something(inners, EMPTY_VEC), something(outers, EMPTY_VEC)))
        splitting_idx = length(inners)
        sys_str = join((string(nameof(s)) * (i <= splitting_idx ? ("::inner") : ("::outer")) for (i, s) in enumerate(syss)), ", ")
        print(io, "<", sys_str, ">")
    end
end

# symbolic `connect`
function connect(sys1::AbstractSystem, sys2::AbstractSystem, syss::AbstractSystem...)
    syss = (sys1, sys2, syss...)
    length(unique(nameof, syss)) == length(syss) || error("connect takes distinct systems!")
    Equation(Connection(), Connection(syss)) # the RHS are connected systems
end

# the actual `connect`.
function connect(c::Connection; check=true)
    @unpack inners, outers = c

    cnts = Iterators.flatten((inners, outers))
    fs, ss = Iterators.peel(cnts)
    splitting_idx = length(inners) # anything after the splitting_idx is outer.
    first_sts = get_states(fs)
    first_sts_set = Set(getname.(first_sts))
    for sys in ss
        current_sts = getname.(get_states(sys))
        Set(current_sts) == first_sts_set || error("$(nameof(sys)) ($current_sts) doesn't match the connection type of $(nameof(fs)) ($first_sts).")
    end

    seen = Set()
    ceqs = Equation[]
    for s in first_sts
        name = getname(s)
        fix_val = getproperty(fs, name) # representative
        fix_val in seen && continue
        push!(seen, fix_val)

        vtype = get_connection_type(fix_val)
        vtype === Stream && continue

        if vtype === Flow
            for j in eachindex(fix_val)
                rhs = 0
                for (i, c) in enumerate(cnts)
                    isinner = i <= splitting_idx
                    var = getproperty(c, name)
                    rhs += isinner ? var[j] : -var[j]
                end
                push!(ceqs, 0 ~ rhs)
            end
        else # Equality
            for c in ss
                var = getproperty(c, name)
                for (i, v) in enumerate(var)
                    push!(ceqs, fix_val[i] ~ v)
                end
            end
        end
    end

    return ceqs
end

instream(a) = term(instream, unwrap(a), type=symtype(a))
SymbolicUtils.promote_symtype(::typeof(instream), _) = Real

isconnector(s::AbstractSystem) = has_connector_type(s) && get_connector_type(s) !== nothing
isstreamconnector(s::AbstractSystem) = isconnector(s) && get_connector_type(s) isa StreamConnector
isstreamconnection(c::Connection) = any(isstreamconnector, c.inners) || any(isstreamconnector, c.outers)

function print_with_indent(n, x)
    print(" " ^ n)
    show(stdout, MIME"text/plain"(), x)
    println()
end

function split_sys_var(var)
    var_name = string(getname(var))
    sidx = findlast(isequal('₊'), var_name)
    sidx === nothing && error("$var is not a namespaced variable")
    connector_name = Symbol(var_name[1:prevind(var_name, sidx)])
    streamvar_name = Symbol(var_name[nextind(var_name, sidx):end])
    connector_name, streamvar_name
end

function flowvar(sys::AbstractSystem)
    sts = get_states(sys)
    for s in sts
        vtype = get_connection_type(s)
        vtype === Flow && return s
    end
    error("There in no flow variable in $(nameof(sys))")
end

collect_instream!(set, eq::Equation) = collect_instream!(set, eq.lhs) | collect_instream!(set, eq.rhs)

function collect_instream!(set, expr, occurs=false)
    istree(expr) || return occurs
    op = operation(expr)
    op === instream && (push!(set, expr); occurs = true)
    for a in SymbolicUtils.unsorted_arguments(expr)
        occurs |= collect_instream!(set, a, occurs)
    end
    return occurs
end

#positivemax(m, ::Any; tol=nothing)= max(m, something(tol, 1e-8))
#_positivemax(m, tol) = ifelse((-tol <= m) & (m <= tol), ((3 * tol - m) * (tol + m)^3)/(16 * tol^3) + tol, max(m, tol))
function _positivemax(m, si)
    T = typeof(m)
    relativeTolerance = 1e-4
    nominal = one(T)
    eps = relativeTolerance * nominal
    alpha = if si > eps
        one(T)
    else
        if si > 0
            (si/eps)^2*(3-2* si/eps)
        else
            zero(T)
        end
    end
    alpha * max(m, 0) + (1-alpha)*eps
end
@register _positivemax(m, tol)
positivemax(m, ::Any; tol=nothing) = _positivemax(m, tol)
mydiv(num, den) = if den == 0
    error()
else
    num / den
end
@register mydiv(n, d)

function generate_isouter(sys::AbstractSystem)
    outer_connectors = Symbol[]
    for s in get_systems(sys)
        n = nameof(s)
        isconnector(s) && push!(outer_connectors, n)
    end
    let outer_connectors=outer_connectors
        function isouter(sys)::Bool
            s = string(nameof(sys))
            isconnector(sys) || error("$s is not a connector!")
            idx = findfirst(isequal('₊'), s)
            parent_name = Symbol(idx === nothing ? s : s[1:prevind(s, idx)])
            parent_name in outer_connectors
        end
    end
end

struct ConnectionSet
    set::Vector{Pair{Any, Bool}} # var => isouter
end

function Base.show(io::IO, c::ConnectionSet)
    print(io, "<")
    for i in 1:length(c.set)-1
        v, isouter = c.set[i]
        print(io, v, "::", isouter ? "outer" : "inner", ", ")
    end
    v, isouter = last(c.set)
    print(io, v, "::", isouter ? "outer" : "inner", ">")
end

@noinline connection_error(ss) = error("Different types of connectors are in one conenction statement: <$(map(nameof, ss))>")

function connection2set!(connectionsets, namespace, ss, isouter)
    sts1 = Set(states(first(ss)))
    T = Pair{Any,Bool}
    csets = [T[] for _ in 1:length(ss)]
    for (i, s) in enumerate(ss)
        sts = states(s)
        i != 1 && ((length(sts1) == length(sts) && all(Base.Fix2(in, sts1), sts)) || connection_error(ss))
        io = isouter(s)
        for (j, v) in enumerate(sts)
            push!(csets[j], T(states(renamespace(namespace, s), v), io))
        end
    end
    for cset in csets
        vtype = get_connection_type(first(cset)[1])
        for k in 2:length(cset)
            vtype === get_connection_type(cset[k][1]) || connection_error(ss)
        end
        push!(connectionsets, ConnectionSet(cset))
    end
end

generate_connection_set(sys::AbstractSystem) = (connectionsets = ConnectionSet[]; generate_connection_set!(connectionsets, sys::AbstractSystem); connectionsets)
function generate_connection_set!(connectionsets, sys::AbstractSystem, namespace=nothing)
    subsys = get_systems(sys)
    # no connectors if there are no subsystems
    isempty(subsys) && return sys

    isouter = generate_isouter(sys)
    eqs′ = get_eqs(sys)
    eqs = Equation[]
    #instream_eqs = Equation[]
    #instream_exprs = []
    cts = [] # connections
    for eq in eqs′
        if eq.lhs isa Connection
            push!(cts, get_systems(eq.rhs))
        #elseif collect_instream!(instream_exprs, eq)
        #    push!(instream_eqs, eq)
        else
            push!(eqs, eq) # split connections and equations
        end
    end

    if namespace !== nothing
        # Except for the top level, all connectors are eventually inside
        # connectors.
        T = Pair{Any,Bool}
        for s in subsys
            isconnector(s) || continue
            for v in states(s)
                Flow === get_connection_type(v) || continue
                push!(connectionsets, ConnectionSet([T(renamespace(namespace, states(s, v)), false)]))
            end
        end
    end

    # if there are no connections, we are done
    isempty(cts) && return sys

    for ct in cts
        connection2set!(connectionsets, namespace, ct, isouter)
    end

    # pre order traversal
    @set! sys.systems = map(s->generate_connection_set!(connectionsets, s, renamespace(namespace, nameof(s))), subsys)
end
#=

 <load₊p₊i(t)::inner>
{<load.p.i, inside>}

 <load₊n₊i(t)::inner>
{<load.n.i, inside>}

 <ground₊g₊i(t)::inner>
{<ground.p.i, inside>}

 <load₊resistor₊p₊i(t)::inner>
{<load.resistor.p.i, inside>}

 <load₊resistor₊n₊i(t)::inner>
{<load.resistor.n.i, inside>}

 <resistor₊p₊i(t)::inner>
{<resistor.p.i, inside>}

 <resistor₊n₊i(t)::inner>
{<resistor.n.i, inside>}


 <resistor.p.i(t)::inner, ground.g.i(t)::inner>
{<resistor.p.i, inside>, <ground.p.i, inside>}

 <resistor.p.v(t)::inner, ground.g.v(t)::inner>
{<resistor.p.v, inside>, <ground.p.v, inside>}

 <load.p.i(t)::inner, ground.g.i(t)::inner>
{<load.p.i, inside>, <ground.p.i, inside>}

 <load.p.v(t)::inner, ground.g.v(t)::inner>
{<load.p.v, inside>, <ground.p.v, inside>}

 <load.p.i(t)::outer, load.resistor.p.i(t)::inner>
{<load.p.i, outside>, <load.resistor.p.i, inside>}

 <load.p.v(t)::outer, load.resistor.p.v(t)::inner>
{<load.p.v, outside>, <load.resistor.p.v, inside>}

 <load.resistor.n.i(t)::inner, load.n.i(t)::outer>
{<load.n.i, outside>, <load.resistor.n.i, inside>}

 <load.resistor.n.v(t)::inner, load.n.v(t)::outer>
{<load.n.v, outside>, <load.resistor.n.v, inside>}
=#

function Base.merge(csets::AbstractVector{<:ConnectionSet})
    mcsets = ConnectionSet[]
    # FIXME: this is O(m n^3)
    for cset in csets
        idx = findfirst(mcset->any(s->any(z->isequal(z, s), cset.set), mcset.set), mcsets)
        if idx === nothing
            push!(mcsets, cset)
        else
            union!(mcsets[idx].set, cset.set)
        end
    end
    mcsets
end

function generate_connection_equations(csets::AbstractVector{<:ConnectionSet})
    eqs = Equation[]
    for cset in csets
        vtype = get_connection_type(cset.set[1][1])
        vtype === Stream && continue
        if vtype === Flow
            rhs = 0
            for (v, isouter) in cset.set
                rhs += isouter ? -v : v
            end
            push!(eqs, 0 ~ rhs)
        else # Equality
            base = cset.set[1][1]
            for i in 2:length(cset.set)
                v = cset.set[i][1]
                push!(eqs, base ~ v)
            end
        end
    end
    eqs
end

function expand_connections(sys::AbstractSystem; debug=false, tol=1e-10,
        rename=Ref{Union{Nothing,Tuple{Symbol,Int}}}(nothing), stream_connects=[])
    subsys = get_systems(sys)
    isempty(subsys) && return sys

    # post order traversal
    @set! sys.systems = map(s->expand_connections(s, debug=debug, tol=tol,
                                                  rename=rename, stream_connects=stream_connects), subsys)

    isouter = generate_isouter(sys)
    sys = flatten(sys)
    eqs′ = get_eqs(sys)
    eqs = Equation[]
    instream_eqs = Equation[]
    instream_exprs = []
    cts = [] # connections
    for eq in eqs′
        if eq.lhs isa Connection
            push!(cts, get_systems(eq.rhs))
        elseif collect_instream!(instream_exprs, eq)
            push!(instream_eqs, eq)
        else
            push!(eqs, eq) # split connections and equations
        end
    end

    # if there are no connections, we are done
    isempty(cts) && return sys

    sys2idx = Dict{Symbol,Int}() # system (name) to n-th connect statement
    narg_connects = Connection[]
    for (i, syss) in enumerate(cts)
        # find intersecting connections
        exclude = 0 # exclude the intersecting system
        idx = 0     # idx of narg_connects
        for (j, s) in enumerate(syss)
            idx′ = get(sys2idx, nameof(s), nothing)
            idx′ === nothing && continue
            idx = idx′
            exclude = j
        end
        if exclude == 0
            outers = []
            inners = []
            for s in syss
                isouter(s) ? push!(outers, s) : push!(inners, s)
            end
            push!(narg_connects, Connection(outers=outers, inners=inners))
            for s in syss
                sys2idx[nameof(s)] = length(narg_connects)
            end
        else
            # fuse intersecting connections
            for (j, s) in enumerate(syss); j == exclude && continue
                sys2idx[nameof(s)] = idx
                c = narg_connects[idx]
                isouter(s) ? push!(c.outers, s) : push!(c.inners, s)
            end
        end
    end

    isempty(narg_connects) && error("Unreachable reached. Please file an issue.")

    @set! sys.connections = narg_connects

    # Bad things happen when there are more than one intersections
    for c in narg_connects
        @unpack outers, inners = c
        len = length(outers) + length(inners)
        allconnectors = Iterators.flatten((outers, inners))
        dups = find_duplicates(nameof(c) for c in allconnectors)
        length(dups) == 0 || error("Connection([$(join(map(nameof, allconnectors), ", "))]) has duplicated connections: [$(join(collect(dups), ", "))].")
    end

    if debug
        println("============BEGIN================")
        println("Connections for [$(nameof(sys))]:")
        foreach(Base.Fix1(print_with_indent, 4), narg_connects)
    end

    connection_eqs = Equation[]
    for c in narg_connects
        ceqs = connect(c)
        debug && append!(connection_eqs, ceqs)
        append!(eqs, ceqs)
    end

    if debug
        println("Connection equations:")
        foreach(Base.Fix1(print_with_indent, 4), connection_eqs)
        println("=============END=================")
    end

    # stream variables
    if rename[] !== nothing
        name, depth = rename[]
        nc = length(stream_connects)
        for i in nc-depth+1:nc
            stream_connects[i] = renamespace(:room, stream_connects[i])
        end
    end
    nsc = 0
    for c in narg_connects
        if isstreamconnection(c)
            push!(stream_connects, c)
            nsc += 1
        end
    end
    rename[] = nameof(sys), nsc
    instream_eqs, additional_eqs = expand_instream(instream_eqs, instream_exprs, stream_connects; debug=debug, tol=tol)

    @set! sys.eqs = [eqs; instream_eqs; additional_eqs]
    return sys
end

@generated function _instream_split(::Val{inner_n}, ::Val{outer_n}, vars::NTuple{N}) where {inner_n, outer_n, N}
    #instream_rt(innerfvs..., innersvs..., outerfvs..., outersvs...)
    ret = Expr(:tuple)
    # mj.c.m_flow
    inner_f = :(Base.@ntuple $inner_n i -> vars[i])
    offset = inner_n
    inner_s = :(Base.@ntuple $inner_n i -> vars[$offset+i])
    offset += inner_n
    # ck.m_flow
    outer_f = :(Base.@ntuple $outer_n i -> vars[$offset+i])
    offset += outer_n
    outer_s = :(Base.@ntuple $outer_n i -> vars[$offset+i])
    Expr(:tuple, inner_f, inner_s, outer_f, outer_s)
end

function instream_rt(ins::Val{inner_n}, outs::Val{outer_n}, vars::Vararg{Any,N}) where {inner_n, outer_n, N}
    @assert N == 2*(inner_n + outer_n)

    # inner: mj.c.m_flow
    # outer: ck.m_flow
    inner_f, inner_s, outer_f, outer_s = _instream_split(ins, outs, vars)

    T = float(first(inner_f))
    si = zero(T)
    num = den = zero(T)
    for f in inner_f
        si += max(-f, 0)
    end
    for f in outer_f
        si += max(f, 0)
    end
    #for (f, s) in zip(inner_f, inner_s)
    for j in 1:inner_n
        @inbounds f = inner_f[j]
        @inbounds s = inner_s[j]
        num += _positivemax(-f, si) * s
        den += _positivemax(-f, si)
    end
    #for (f, s) in zip(outer_f, outer_s)
    for j in 1:outer_n
        @inbounds f = outer_f[j]
        @inbounds s = outer_s[j]
        num += _positivemax(-f, si) * s
        den += _positivemax(-f, si)
    end
    return num / den
    #=
    si = sum(max(-mj.c.m_flow,0) for j in cat(1,1:i-1, i+1:N)) +
            sum(max(ck.m_flow ,0) for k  in 1:M)

    inStream(mi.c.h_outflow) =
       (sum(positiveMax(-mj.c.m_flow,si)*mj.c.h_outflow)
      +  sum(positiveMax(ck.m_flow,s_i)*inStream(ck.h_outflow)))/
     (sum(positiveMax(-mj.c.m_flow,s_i))
        +  sum(positiveMax(ck.m_flow,s_i)))
                  for j in 1:N and i <> j and mj.c.m_flow.min < 0,
                  for k in 1:M and ck.m_flow.max > 0
    =#
end
SymbolicUtils.promote_symtype(::typeof(instream_rt), ::Vararg) = Real

function expand_instream(instream_eqs, instream_exprs, connects; debug=false, tol)
    sub = Dict()
    seen = Set()
    for ex in instream_exprs
        var = only(arguments(ex))
        connector_name, streamvar_name = split_sys_var(var)

        # find the connect
        cidx = findfirst(c->connector_name in c, connects)
        cidx === nothing && error("$var is not a variable inside stream connectors")
        connect = connects[cidx]
        connectors = Iterators.flatten((connect.inners, connect.outers))
        # stream variable
        sv = getproperty(first(connectors), streamvar_name; namespace=false)
        inner_sc = something(connect.inners, EMPTY_VEC)
        outer_sc = something(connect.outers, EMPTY_VEC)

        n_outers = length(outer_sc)
        n_inners = length(inner_sc)
        outer_names = (nameof(s) for s in outer_sc)
        inner_names = (nameof(s) for s in inner_sc)
        if debug
            println("Expanding: $ex")
            isempty(inner_names) || println("Inner connectors: $(collect(inner_names))")
            isempty(outer_names) || println("Outer connectors: $(collect(outer_names))")
        end

        # expand `instream`s
        # https://specification.modelica.org/v3.4/Ch15.html
        # Based on the above requirements, the following implementation is
        # recommended:
        if n_inners == 1 && n_outers == 0
            connector_name === only(inner_names) || error("$var is not in any stream connector of $(nameof(ogsys))")
            sub[ex] = var
        elseif n_inners == 2 && n_outers == 0
            connector_name in inner_names || error("$var is not in any stream connector of $(nameof(ogsys))")
            idx = findfirst(c->nameof(c) === connector_name, inner_sc)
            other = idx == 1 ? 2 : 1
            sub[ex] = states(inner_sc[other], sv)
        elseif n_inners == 1 && n_outers == 1
            isinner = connector_name === only(inner_names)
            isouter = connector_name === only(outer_names)
            (isinner || isouter) || error("$var is not in any stream connector of $(nameof(ogsys))")
            if isinner
                outerstream = states(only(outer_sc), sv) # c_1.h_outflow
                sub[ex] = outerstream
            end
        else
            fv = flowvar(first(connectors))
            i = findfirst(c->nameof(c) === connector_name, inner_sc)
            if i !== nothing
                # mj.c.m_flow
                innerfvs = [unwrap(states(s, fv)) for (j, s) in enumerate(inner_sc) if j != i]
                innersvs = [unwrap(states(s, sv)) for (j, s) in enumerate(inner_sc) if j != i]
                # ck.m_flow
                outerfvs = [unwrap(states(s, fv)) for s in outer_sc]
                outersvs = [instream(states(s, fv)) for s in outer_sc]

                sub[ex] = term(instream_rt, Val(length(innerfvs)), Val(length(outerfvs)), innerfvs..., innersvs..., outerfvs..., outersvs...)
                #=
                si = isempty(outer_sc) ? 0 : sum(s->max(states(s, fv), 0), outer_sc)
                for j in 1:n_inners; j == i && continue
                    f = states(inner_sc[j], fv)
                    si += max(-f, 0)
                end

                num = 0
                den = 0
                for j in 1:n_inners; j == i && continue
                    f = states(inner_sc[j], fv)
                    tmp = positivemax(-f, si; tol=tol)
                    den += tmp
                    num += tmp * states(inner_sc[j], sv)
                end
                for k in 1:n_outers
                    f = states(outer_sc[k], fv)
                    tmp = positivemax(f, si; tol=tol)
                    den += tmp
                    num += tmp * instream(states(outer_sc[k], sv))
                end
                sub[ex] = mydiv(num, den)
                =#
            end
        end
    end

    # additional equations
    additional_eqs = Equation[]
    for c in connects
        outer_sc = something(c.outers, EMPTY_VEC)
        isempty(outer_sc) && continue
        inner_sc = c.inners
        n_outers = length(outer_sc)
        n_inners = length(inner_sc)
        connector_representative = first(outer_sc)
        fv = flowvar(connector_representative)
        for sv in get_states(connector_representative)
            vtype = get_connection_type(sv)
            vtype === Stream || continue
            if n_inners == 1 && n_outers == 1
                innerstream = states(only(inner_sc), sv)
                outerstream = states(only(outer_sc), sv)
                push!(additional_eqs, outerstream ~ innerstream)
            elseif n_inners == 0 && n_outers == 2
                # we don't expand `instream` in this case.
                v1 = states(outer_sc[1], sv)
                v2 = states(outer_sc[2], sv)
                push!(additional_eqs, v1 ~ instream(v2))
                push!(additional_eqs, v2 ~ instream(v1))
            else
                sq = 0
                for q in 1:n_outers
                    sq += sum(s->max(-states(s, fv), 0), inner_sc)
                    for k in 1:n_outers; k == q && continue
                        f = states(outer_sc[k], fv)
                        sq += max(f, 0)
                    end

                    num = 0
                    den = 0
                    for j in 1:n_inners
                        f = states(inner_sc[j], fv)
                        tmp = positivemax(-f, sq; tol=tol)
                        den += tmp
                        num += tmp * states(inner_sc[j], sv)
                    end
                    for k in 1:n_outers; k == q && continue
                        f = states(outer_sc[k], fv)
                        tmp = positivemax(f, sq; tol=tol)
                        den += tmp
                        num += tmp * instream(states(outer_sc[k], sv))
                    end
                    push!(additional_eqs, states(outer_sc[q], sv) ~ num / den)
                end
            end
        end
    end

    instream_eqs = map(Base.Fix2(substitute, sub), instream_eqs)
    if debug
        println("===========BEGIN=============")
        println("Expanded equations:")
        for eq in instream_eqs
            print_with_indent(4, eq)
        end
        if !isempty(additional_eqs)
            println("Additional equations:")
            for eq in additional_eqs
                print_with_indent(4, eq)
            end
        end
        println("============END==============")
    end
    return instream_eqs, additional_eqs
end

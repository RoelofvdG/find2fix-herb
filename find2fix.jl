using Herb, HerbConstraints

let flags = Dict{String,String}()
    bool_flags = Set{String}()
    i = 1
    while i <= length(ARGS)
        if startswith(ARGS[i], "--") && i + 1 <= length(ARGS) && !startswith(ARGS[i+1], "--")
            flags[ARGS[i][3:end]] = ARGS[i+1]
            i += 2
        elseif startswith(ARGS[i], "--")
            push!(bool_flags, ARGS[i][3:end])
            i += 1
        else
            error("Expected --flag value, got: $(ARGS[i])")
        end
    end
    global templates_file   = get(flags, "templates",    "templates.txt")
    global context_file     = get(flags, "context",      "context.txt")
    global hierarchy_file   = get(flags, "hierarchy",    "type_hierarchy.txt")
    global target_type_file = get(flags, "target-type",  "target_type.txt")
    global production_mode  = "production" in bool_flags
end

# Sanitize Java type names (e.g. "int[]", "Point2D.Double") to valid Julia symbols.
function sanitize_type(t::AbstractString)
    t = strip(t)
    t = last(split(t, "."))   # drop Java package prefix: java.awt.Shape -> Shape
    t = replace(t, "[]" => "Array")
    t = replace(t, r"[<> $]" => "")
    return Symbol(t)
end

# Parses templates.txt and defines template_n functions for each non-terminal template.
# Returns a Vector of NamedTuples (name, return_type, arg_types, code, variables).
# Does NOT add rules to any grammar — call add_templates_to_grammar! for that.
function parse_templates(filename::String)
    content = read(filename, String)
    raw_templates = split(content, "###")
    records = []

    for (n, template_str) in enumerate(raw_templates)
        template = strip(template_str)
        isempty(template) && continue

        # Parse "code -> JavaASTType -> returnType -> ClassName -> PackageName -> occurrenceCount"
        parts = split(template, " -> ")
        length(parts) < 6 && continue

        occurrence_count = parse(Int, strip(parts[end]))
        return_type = sanitize_type(String(parts[end-3]))
        code = strip(join(parts[1:end-5], " -> "))

        # Extract unique variables (_TypeName_N) in order of first occurrence
        seen = Set{String}()
        variables = Symbol[]
        arg_types = Symbol[]
        for m in eachmatch(r"_([A-Za-z][A-Za-z0-9\[\]]*)_\d+", code)
            var_str = m.match
            if var_str ∉ seen
                push!(seen, var_str)
                push!(variables, Symbol(var_str))
                push!(arg_types, sanitize_type(m.captures[1]))
            end
        end

        name = Symbol("template", n)

        if !isempty(variables)
            @eval function $(name)($(variables...))
                return replace($code, $([:( $(string(v)) => string($(v)) ) for v in variables]...))
            end
        end

        push!(records, (name=name, return_type=return_type, arg_types=arg_types, code=code, variables=variables, occurrence_count=occurrence_count))
    end

    return records
end

# Reads context.txt and adds terminal/non-terminal grammar rules for:
#   - in-scope variables  (NAME : type : global_freq : local_freq)
#   - enclosing class methods  (method(params) : ret : global_freq : local_freq)
#   - instance methods on in-scope objects  (same shape)
#
# Also returns:
#   initial_types        – Set{Symbol} of variable/field/zero-arg-method return types
#   ctx_method_rules     – Vector of (return_type, param_types, global_freq, local_freq)
#   ctx_terminal_entries – Vector of (kind, name, ret_type, global_freq, local_freq)
function load_context(filename::String, grammar::AbstractGrammar)
    lines = readlines(filename)
    section = :variables
    method_counter = 0
    initial_types = Set{Symbol}()
    ctx_method_rules = []
    ctx_terminal_entries = []

    for line in lines
        line = strip(line)
        isempty(line) && continue
        if startswith(line, "# Variables");         section = :variables;         continue; end
        if startswith(line, "# Methods of");        section = :class_methods;     continue; end
        if startswith(line, "# Methods reachable"); section = :instance_methods;  continue; end
        if startswith(line, "# Fields");            section = :fields;            continue; end
        startswith(line, "#") && continue

        # All lines: "... : type : global_freq : local_freq"
        parts = split(line, " : ")
        length(parts) < 4 && continue
        global_freq = parse(Int, strip(parts[end-1]))
        local_freq  = parse(Int, strip(parts[end]))

        p = max(local_freq, 1)

        if section == :variables
            varname  = strip(parts[1])
            ret_type = sanitize_type(parts[end-2])
            add_rule!(grammar, p, :($ret_type = $varname); normalize=false)
            push!(initial_types, ret_type)
            push!(ctx_terminal_entries, (kind=:variable, name=varname, ret_type=ret_type, global_freq=global_freq, local_freq=local_freq))

        elseif section == :fields
            field_access = strip(join(parts[1:end-3], " : "))
            ret_type     = sanitize_type(parts[end-2])
            add_rule!(grammar, p, :($ret_type = $field_access); normalize=false)
            push!(initial_types, ret_type)
            push!(ctx_terminal_entries, (kind=:field, name=field_access, ret_type=ret_type, global_freq=global_freq, local_freq=local_freq))

        else  # :class_methods or :instance_methods — same shape, different prefix
            ret_type   = sanitize_type(parts[end-2])
            method_sig = strip(join(parts[1:end-3], " : "))

            m = match(r"^([\w.]+)\((.*)\)$", method_sig)
            m === nothing && continue
            prefix     = String(m.captures[1])   # e.g. "clone" or "iterator1.currentSegment"
            params_str = strip(m.captures[2])

            if isempty(params_str)
                call = prefix * "()"
                add_rule!(grammar, p, :($ret_type = $call); normalize=false)
                push!(initial_types, ret_type)
                push!(ctx_terminal_entries, (kind=:method, name=call, ret_type=ret_type, global_freq=global_freq, local_freq=local_freq))
            else
                param_types = [sanitize_type(pt) for pt in split(params_str, ", ")]
                method_counter += 1
                fname   = Symbol("context_method_", method_counter)
                fparams = [Symbol("arg", i) for i in 1:length(param_types)]
                call_prefix = prefix * "("
                @eval function $(fname)($(fparams...))
                    return $call_prefix * join([$(fparams...)], ", ") * ")"
                end
                add_rule!(grammar, p, :($ret_type = $(fname)($(param_types...))); normalize=false)
                push!(ctx_method_rules, (return_type=ret_type, param_types=param_types, global_freq=global_freq, local_freq=local_freq))
            end
        end
    end

    return grammar, initial_types, ctx_method_rules, ctx_terminal_entries
end

# Parses type_hierarchy.txt and returns a Vector of NamedTuples (child_type, parent_type).
# Does NOT add rules to any grammar — call add_hierarchy_to_grammar! for that.
function parse_type_hierarchy(filename::String)
    records = []
    for line in readlines(filename)
        line = strip(line)
        isempty(line) && continue
        parts = split(line, " -> ")
        length(parts) != 3 && continue
        child_type  = sanitize_type(parts[1])
        parent_type = sanitize_type(parts[3])
        push!(records, (child_type=child_type, parent_type=parent_type))
    end
    return records
end

# Fixpoint reachability: starting from initial_types, iteratively expand the set of
# reachable types by firing hierarchy rules (child → parent) and template/method rules
# (all args reachable → return type reachable). Terminal templates (empty arg_types)
# are always reachable and their return types are added in the first pass.
function compute_reachable_types(initial_types, template_records, hierarchy_records, ctx_method_rules)
    reachable = copy(initial_types)
    changed = true
    while changed
        changed = false
        for r in hierarchy_records
            if r.child_type ∈ reachable && r.parent_type ∉ reachable
                push!(reachable, r.parent_type)
                changed = true
            end
        end
        for t in template_records
            if t.return_type ∉ reachable && all(a ∈ reachable for a in t.arg_types)
                push!(reachable, t.return_type)
                changed = true
            end
        end
        for m in ctx_method_rules
            if m.return_type ∉ reachable && all(p ∈ reachable for p in m.param_types)
                push!(reachable, m.return_type)
                changed = true
            end
        end
    end
    return reachable
end

# Adds grammar rules for template records whose arg_types are all reachable.
function add_templates_to_grammar!(grammar, records)
    for t in records
        p = max(t.occurrence_count, 1)
        if isempty(t.arg_types)
            add_rule!(grammar, p, :($(t.return_type) = $(t.code)); normalize=false)
        else
            add_rule!(grammar, p, :($(t.return_type) = $(t.name)($(t.arg_types...))); normalize=false)
        end
    end
end

# Adds grammar rules for hierarchy records whose child_type is reachable.
function add_hierarchy_to_grammar!(grammar, records)
    for r in records
        add_rule!(grammar, 1, :($(r.parent_type) = $(r.child_type)); normalize=false)
    end
end

target_type_str = let
    kv = filter(l -> startswith(strip(l), "type:"), readlines(target_type_file))
    isempty(kv) ? error("No 'type:' entry found in $target_type_file") : sanitize_type(split(kv[1], ":", limit=2)[2])
end
type_var = target_type_str
start_expr = quote 1 : Start = $type_var end
grammar = HerbGrammar.expr2pcsgrammar(start_expr)

# grammar = HerbConstraints.@pcsgrammar begin
#     1 : $exp
# end

template_records  = parse_templates(templates_file)
grammar, initial_types, ctx_method_rules, ctx_terminal_entries = load_context(context_file, grammar)
hierarchy_records = parse_type_hierarchy(hierarchy_file)

reachable = compute_reachable_types(initial_types, template_records, hierarchy_records, ctx_method_rules)

usable_templates  = filter(t -> all(a ∈ reachable for a in t.arg_types), template_records)
usable_hierarchy  = filter(r -> r.child_type ∈ reachable, hierarchy_records)

add_templates_to_grammar!(grammar, usable_templates)
add_hierarchy_to_grammar!(grammar, usable_hierarchy)
normalize!(grammar)

if production_mode
    println("Grammar contains $(length(grammar.rules)) rules")
else
    for (i, (type, rule)) in enumerate(zip(grammar.types, grammar.rules))
        println("$i: $type = $rule")
    end
end

iterator = HerbSearch.BFSIterator(grammar, :Start, max_depth=3)
candidate_count = 0
for rn in iterator
    expr = rulenode2expr(rn, grammar)
    try
        println("Testing candidate: (", @eval($expr), ")")
        global candidate_count += 1
    catch e
        if e isa UndefVarError
            # println("Undefined variable in candidate: ", e)
            continue
            # consider removing the bad type from the grammar
        else
            throw(e)
        end
    end
    if production_mode && candidate_count >= 300
        break
    end
    # <Java stuff :) >
end

using Herb, HerbConstraints

templates_file = length(ARGS) >= 1 ? ARGS[1] : "templates.txt"
context_file   = length(ARGS) >= 2 ? ARGS[2] : "context.txt"
hierarchy_file = length(ARGS) >= 3 ? ARGS[3] : "type_hierarchy.txt"

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

        # Parse "code -> JavaASTType -> returnType -> ClassName -> PackageName"
        parts = split(template, " -> ")
        length(parts) < 5 && continue

        return_type = sanitize_type(String(parts[end-2]))
        code = strip(join(parts[1:end-4], " -> "))

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

        push!(records, (name=name, return_type=return_type, arg_types=arg_types, code=code, variables=variables))
    end

    return records
end

# Reads context.txt and adds terminal/non-terminal grammar rules for:
#   - in-scope variables  (NAME : type  →  terminal: type = "NAME")
#   - enclosing class methods  (method(params) : ret  →  ret = context_n(paramTypes...))
#   - instance methods on in-scope objects  (obj.method(params) : ret  →  same pattern)
#
# Also returns:
#   initial_types     – Set{Symbol} of variable types and zero-arg method return types
#   ctx_method_rules  – Vector of (return_type, param_types) for parameterized methods
function load_context(filename::String, grammar::AbstractGrammar)
    lines = readlines(filename)
    section = :variables
    method_counter = 0
    initial_types = Set{Symbol}()
    ctx_method_rules = []

    for line in lines
        line = strip(line)
        isempty(line) && continue
        if startswith(line, "# Variables");         section = :variables;         continue; end
        if startswith(line, "# Methods of");        section = :class_methods;     continue; end
        if startswith(line, "# Methods reachable"); section = :instance_methods;  continue; end
        if startswith(line, "# Fields");            section = :fields;            continue; end
        startswith(line, "#") && continue

        if section == :variables
            # "VARNAME : java.type"
            parts = split(line, " : ", limit=2)
            length(parts) != 2 && continue
            varname  = strip(parts[1])
            ret_type = sanitize_type(parts[2])
            add_rule!(grammar, :($ret_type = $varname))
            push!(initial_types, ret_type)

        elseif section == :fields
            # "obj.fieldName : type"
            parts = split(line, " : ", limit=2)
            length(parts) != 2 && continue
            ret_type     = sanitize_type(parts[2])
            field_access = strip(parts[1])
            add_rule!(grammar, :($ret_type = $field_access))
            push!(initial_types, ret_type)

        else  # :class_methods or :instance_methods — same shape, different prefix
            # "prefix(param1, param2, ...) : returnType"
            parts = split(line, " : ", limit=2)
            length(parts) != 2 && continue
            ret_type = sanitize_type(parts[2])

            m = match(r"^([\w.]+)\((.*)\)$", strip(parts[1]))
            m === nothing && continue
            prefix    = String(m.captures[1])   # e.g. "clone" or "iterator1.currentSegment"
            params_str = strip(m.captures[2])

            if isempty(params_str)
                # Zero-param method → terminal string "prefix()"
                call = prefix * "()"
                add_rule!(grammar, :($ret_type = $call))
                push!(initial_types, ret_type)
            else
                param_types = [sanitize_type(p) for p in split(params_str, ", ")]
                method_counter += 1
                fname  = Symbol("context_method_", method_counter)
                fparams = [Symbol("arg", i) for i in 1:length(param_types)]
                call_prefix = prefix * "("
                @eval function $(fname)($(fparams...))
                    return $call_prefix * join([$(fparams...)], ", ") * ")"
                end
                add_rule!(grammar, :($ret_type = $(fname)($(param_types...))))
                push!(ctx_method_rules, (return_type=ret_type, param_types=param_types))
            end
        end
    end

    return grammar, initial_types, ctx_method_rules
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
        if isempty(t.arg_types)
            add_rule!(grammar, :($(t.return_type) = $(t.code)))
        else
            add_rule!(grammar, :($(t.return_type) = $(t.name)($(t.arg_types...))))
        end
    end
end

# Adds grammar rules for hierarchy records whose child_type is reachable.
function add_hierarchy_to_grammar!(grammar, records)
    for r in records
        add_rule!(grammar, :($(r.parent_type) = $(r.child_type)))
    end
end

type_var = :(boolean)
start_expr = quote 1 : Start = $type_var end
grammar = HerbGrammar.expr2pcsgrammar(start_expr)

# grammar = HerbConstraints.@pcsgrammar begin
#     1 : $exp
# end

template_records  = parse_templates(templates_file)
grammar, initial_types, ctx_method_rules = load_context(context_file, grammar)
hierarchy_records = parse_type_hierarchy(hierarchy_file)

reachable = compute_reachable_types(initial_types, template_records, hierarchy_records, ctx_method_rules)

usable_templates  = filter(t -> all(a ∈ reachable for a in t.arg_types), template_records)
usable_hierarchy  = filter(r -> r.child_type ∈ reachable, hierarchy_records)

add_templates_to_grammar!(grammar, usable_templates)
add_hierarchy_to_grammar!(grammar, usable_hierarchy)

for (i, (type, rule)) in enumerate(zip(grammar.types, grammar.rules))
    println("$i: $type = $rule")
end

iterator = HerbSearch.BFSIterator(grammar, :Start, max_depth=3)
for rn in iterator
    expr = rulenode2expr(rn, grammar)
    try
        println("Testing candidate: ", @eval $expr)
    catch e
        if e isa UndefVarError
            # println("Undefined variable in candidate: ", e)
            continue
            # consider removing the bad type from the grammar
        else
            throw(e)
        end
    end
    # <Java stuff :) >
end

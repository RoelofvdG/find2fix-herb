using Herb, HerbGrammar, HerbConstraints, HerbSpecification, HerbSearch, HerbInterpret
using Herb
grammar = HerbConstraints.@csgrammar begin
    Start = Bool
    Bool = template1(SomeType, Bool)
    Bool = template2(Bool, Bool)
    Bool = "true" | "false" | "V1" | "V2"
end

println("aaaa")

function template1(_boolean_1::String, _boolean_2::String)
    return "$(_boolean_1) || $(_boolean_2)"
end

function template4(_Poly_1::String, Poly2::String, IntArr::String)
    return "$_Poly_1.$IntArr + $Poly2 > $(IntArr)"
end

for t in [1]
    name = :template2
    variables = [:_boolean_1, :_boolean_2]
    template = "_boolean_1 && _boolean_2"

    # Define template2 such that variable names in `template` (e.g. "Bool1") are
    # replaced at runtime with the string value of the corresponding argument.
    @eval function $(name)($(variables...))
        return replace($template, $( [:( $(string(v)) => string($(v)) ) for v in variables]... ))
    end
end

iterator = HerbSearch.BFSIterator(grammar, :Start, max_depth=3)
for rn in iterator
    expr = rulenode2expr(rn, grammar)
    try 
        println("Testing candidate: ", @eval $expr)
    catch e
        if e isa UndefVarError
            println("Undefined variable in candidate: ", e)
            # consider removing the bad type from the grammar
        else
            throw(e)
        end
    end
    # <Java stuff :) >
end
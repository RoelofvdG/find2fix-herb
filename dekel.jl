# using Herb
using Herb, HerbGrammar, HerbConstraints, HerbSpecification, HerbSearch

# define our very simple context-free grammar
grammar = HerbConstraints.@csgrammar begin
    Start = double
    double = x
    double = performSophisticatedCalculation(double)
    double = Math.max(double, double)
    double = Math.min(double, double)
end

# define a breadth-first iterator over program trees with root node :Start and max depth 5
iterator = HerbSearch.BFSIterator(grammar, :Start, max_depth=5)
for rn in iterator
    # convert the solution from a syntax tree to a Julia expression, and print it
    expr = rulenode2expr(rn, grammar)
    println("Testing candidate: ", expr)
end

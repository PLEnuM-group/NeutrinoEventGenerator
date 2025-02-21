using NeutrinoEventGenerator
using Documenter

DocMeta.setdocmeta!(NeutrinoEventGenerator, :DocTestSetup, :(using NeutrinoEventGenerator); recursive=true)

makedocs(;
    modules=[NeutrinoEventGenerator],
    authors="Christian Haack <chr.hck@gmail.com>",
    sitename="NeutrinoEventGenerator.jl",
    format=Documenter.HTML(;
        canonical="https://chrhck.github.io/NeutrinoEventGenerator.jl",
        edit_link="main",
        assets=String[],
    ),
    pages=[
        "Home" => "index.md",
    ],
)

deploydocs(;
    repo="github.com/chrhck/NeutrinoEventGenerator.jl",
    devbranch="main",
)

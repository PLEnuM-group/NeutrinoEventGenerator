module NeutrinoEventGenerator

using Reexport

include("event.jl")
include("injectors.jl")
include("event_collection.jl")
include("utils.jl")

export Event, get_lightemitting_particles

@reexport using .Injectors


end

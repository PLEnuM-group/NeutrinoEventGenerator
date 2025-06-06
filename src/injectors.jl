module Injectors

using Random
using StaticArrays
using Distributions
using PhysicsTools
using UUIDs
using StructTypes
using Rotations
using DataFrames
using HDF5
import Base.rand
import ..Event

export sample_volume, inject
export Cylinder, Cuboid, VolumeType, Sphere
export SurfaceType, CylinderSurface
export VolumeInjector, Injector
export SurfaceInjector
export LIInjector
export ParticleTypeDistribution
export AngularDistribution, UniformAngularDistribution
export LowerHalfSphere
export get_intersection
export sample_uniform_ray
export maximum_proj_area, projected_area
export get_volume
export is_volume, is_surface
export point_in_volume
export acceptance
export chord_length

"""
    VolumeType

Abstract type for volumes
"""
abstract type VolumeType end

point_in_volume(::VolumeType, ::AbstractVector) = error("Not implemented")
StructTypes.StructType(::Type{<:VolumeType}) = StructTypes.Struct()

"""
    Cylinder{T} <: VolumeType

Cylinder(center, height, radius).

Type for cylindrical volumes.
"""
struct Cylinder{T} <: VolumeType
    center::SVector{3,T}
    height::T
    radius::T
end

Base.:(==)(a::Cylinder, b::Cylinder) = (a.center == b.center) && (a.height == b.height) && (a.radius == b.radius)

function point_in_volume(c::Cylinder, pos::AbstractVector)

    rel_pos = pos .- c.center

    height_check = (rel_pos[3] > -c.height /2) && (rel_pos[3] < c.height/2)
    circle_check = (rel_pos[1]^2 + rel_pos[2]^2) < c.radius^2

    return height_check && circle_check
end

"""
    Cuboid{T} <: VolumeType

Type for cuboid volumes.
"""
struct Cuboid{T} <: VolumeType
    center::SVector{3,T}
    l_x::T
    l_y::T
    l_z::T
end

Base.:(==)(a::Cuboid, b::Cuboid) = (a.l_x == b.l_x) && (a.l_y == b.l_y) && (a.l_z == b.l_z)


"""
    Sphere{T} <: VolumeType

Type for spherical volumes.
"""
struct Sphere{T} <: VolumeType
    center::SVector{3,T}
    radius::T
end

Base.:(==)(a::Sphere, b::Sphere) = (a.center == b.center) && (a.radius == b.radius)

function point_in_volume(s::Sphere, pos::AbstractVector)
    return norm(pos .- s.center) < s.radius
end


"""
    FixedPosition{T} <: VolumeType

Dummy type representing a fixed point. Used for sampling a 3D-Delta Distribution
"""
struct FixedPosition{T} <: VolumeType
    position::SVector{3,T}
end

Base.:(==)(a::FixedPosition, b::FixedPosition) = all(a.position .== b.position)

point_in_volume(c::FixedPosition, pos::AbstractVector) = pos == c.position


"""
    rand(::VolumeType)

Sample a random point in volume
"""
rand(vol::VolumeType) = rand(Random.default_rng(), vol)
rand(::AbstractRNG, vol::FixedPosition) = vol.position

"""
    rand(vol::Cylinder{T}) where {T}

Sample a random point in Cylinder.
"""
function rand(rng::AbstractRNG, vol::Cylinder{T}) where {T}
    uni = Uniform(-vol.height / 2, vol.height / 2)
    rng_z = rand(rng, uni)

    rng_r = sqrt(rand(rng, T) * vol.radius^2)
    rng_phi = rand(rng, T) * 2 * π
    rng_x = rng_r * cos(rng_phi)
    rng_y = rng_r * sin(rng_phi)

    return SA{T}[rng_x, rng_y, rng_z] + vol.center
end



"""
    rand(vol::Cuboid{T}) where {T}

Sample a random point in Cuboid.
"""
function rand(rng::AbstractRNG, vol::Cuboid{T}) where {T}
    uni_x = Uniform(-vol.l_x / 2, vol.l_x / 2)
    uni_y = Uniform(-vol.l_y / 2, vol.l_y / 2)
    uni_z = Uniform(-vol.l_z / 2, vol.l_z / 2)
    return SA{T}[rand(rng, uni_x), rand(rng, uni_y), rand(rng, uni_z)] + vol.center

end

"""
    rand(vol::Sphere{T}) where {T}

Sample a random point in Sphere.
"""
function rand(rng::AbstractRNG, vol::Sphere{T}) where {T}
    uni_r3 = rand(rng)
    uni_costheta = rand(Uniform(-1, 1))
    uni_phi = rand(Uniform(0, 2*π))

    cart = T.(vol.radius * cbrt(uni_r3) .* sph_to_cart(acos(uni_costheta), uni_phi) .+ vol.center)

    return cart
end

"""
    get_volume(::VolumeType)
Calculate volume.
"""
get_volume(::VolumeType) = error("not implemented")
get_volume(c::Cylinder) = c.radius^2 * π * c.height
get_volume(c::Cuboid) = c.l_x * c.l_y * c.l_z
get_volume(s::Sphere) = 4/3 * π * s.radius^3

"""
SurfaceType
    Abstract type for surfaces
"""
abstract type SurfaceType end

"""
    CylinderSurface{T} <: SurfaceType
Type for cylinder surfaces
"""
struct CylinderSurface{T} <: SurfaceType
    center::SVector{3,T}
    height::T
    radius::T
end

Base.:(==)(a::CylinderSurface, b::CylinderSurface) = (a.center == b.center) && (a.height == b.height) && (a.radius == b.radius)

"""
    CylinderSurface{T} <: SurfaceType
Type for Sphere surfaces
"""
struct SphereSurface{T} <: SurfaceType
    center::SVector{3,T}
    radius::T
end


"""
    CylinderSurface(c::Cylinder)
Create a cylinder surface from cylinder
"""
CylinderSurface(c::Cylinder) = CylinderSurface(c.center, c.height, c.radius)

"""
    Cylinder(c::CylinderSurface)
Create a cylinder from cylinder surface
"""
Cylinder(c::CylinderSurface) = Cylinder(c.center, c.height, c.radius)

"""
    Base.rand([rng::AbstractRNG=default_rng()], c::CylinderSurface{T}) where {T}

Uniformly sample a point on the cylinder surface. Note that this does not sample impact points
for rays from a uniform flux (see `sample_uniform_ray`).
"""
function Base.rand(rng::AbstractRNG, c::CylinderSurface{T}) where {T}

    cap_area = π*c.radius^2
    mantle_area = 2*π*c.radius*c.height

    cap_prob = cap_area / (cap_area + mantle_area)

    if rand(rng) < cap_prob
        
        # Uniform in one of the caps
        pos_z = c.center[3] + rand(rng, [-1, 1]) * c.height/2

        radius = sqrt(rand(rng)*c.radius^2)
        phi = rand(rng, Uniform(0, 2*π))
        pos_x = cos(phi) * radius
        pos_y = sin(phi) * radius

        return SA{T}[pos_x, pos_y, pos_z]

    else
        # Mantle
        pos_z = rand(rng, Uniform(-c.height/2, c.height/2)) + c.center[3]
        phi = rand(rng, Uniform(0, 2 * π))
        pos_x = c.radius * cos(phi)
        pos_y = c.radius * sin(phi)
        return SA{T}[pos_x, pos_y, pos_z]
    end

end

Base.rand(c::CylinderSurface) = rand(Random.default_rng(), c)

get_surface_normal(::SurfaceType, pos) = error("Not defined")

function get_surface_normal(c::CylinderSurface{T}, pos) where {T <: Real}
    if abs(pos[3]) == c.height /2 + c.center[3]
        # endcap
        return  SA{T}[0, 0, sign(pos[3] - c.center[3])]
    else
        # mantle
        _, phi, _ = cart_to_cyl(pos)
        return SA{T}[cos(phi), sin(phi), 0]
    end
end

is_surface(::Any) = false
is_surface(::SurfaceType) = true

is_volume(::Any) = false
is_volume(::VolumeType) = true

mutable struct Intersection{T}
    first::Union{Nothing, T}
    second::Union{Nothing, T}

    function Intersection(first, second)
        T = promote_type(typeof(first), typeof(second))

        if isnothing(first) || isnothing(second)
            return new{T}(first, second)
        else
            if first <=second
                return new{T}(first, second)
            else
                return new{T}(second, first)
            end
        end        
    end
end

"""
    get_intersection(::VolumeType, position, direction) = error("Not implemented")
Calculate intersection of a line x : position + t*direction with volume
"""
get_intersection(::VolumeType, position, direction) = error("Not implemented")

"""
    get_intersection(c::Cylinder{T}, position, direction) where {T <: Real}
    Calculate intersection with cylinder.

    Code adapted from Jakob van Santen.
"""
function get_intersection(c::CylinderSurface{T}, position, direction) where {T <: Real}
    
    x, y, z = position .- c.center

    dir_sph = cart_to_sph(.-direction)
    sinth = sin(dir_sph[1])
    costh = cos(dir_sph[1])
    sinph = sin(dir_sph[2])
    cosph = cos(dir_sph[2])     
   
	
	b = x * cosph + y * sinph
    d = b^2 + c.radius^2 - x^2 - y^2

    i1 = Intersection(nothing, nothing)
    i2 = Intersection(nothing, nothing)

    if d > 0
        d = sqrt(d)
        # down-track distance to the endcaps
		if (costh != 0) 
            i1 = Intersection((z - c.height/2)/costh, (z + c.height/2)/costh)
        end
		
		# down-track distance to the side surfaces
        if (sinth != 0)
            i2 = Intersection((b - d)/sinth, (b + d)/sinth)
        end

        # Perfectly horizontal tracks never intersect the endcaps
        if (costh == 0)
            if ((z > -c.height/2) && (z < c.height/2))
                i1 = i2
            else
                i1 = Intersection(nothing, nothing)
            end
        # Perfectly vertical tracks never intersect the sides
		elseif  (sinth == 0)
            if (hypot(x, y) >= c.radius)
                i1 = Intersection(nothing, nothing)
            end
		# For general tracks, take the last entrace and first exit
		else
		    if (i1.first >= i2.second || i1.second <= i2.first)
				i1 = Intersection(nothing, nothing)
			else
                i1 = Intersection(max(i2.first, i1.first), min(i2.second, i1.second))
            end
		end
    end
    return i1
end

get_intersection(c::Cylinder, position, direction) = get_intersection(CylinderSurface(c), position, direction)
get_intersection(vol_or_surface, particle::Particle) = get_intersection(vol_or_surface, particle.position, particle.direction)

projected_area(::VolumeType, direction) = error("not implemented")
function projected_area(c::Cylinder, direction::AbstractArray)
    projected_area(c, direction[3])
	
end

function projected_area(c::Cylinder, cos_theta::Real)
    cap = π*c.radius^2
	sides = 2*c.radius*c.height
	return cap*abs(cos_theta) + sides*sqrt(1 - cos_theta^2)
end

maximum_proj_area(::VolumeType) = error("not implemented")
maximum_proj_area(c::Cylinder) = projected_area(c, cos(atan(2*c.height/(π*c.radius))))


acceptance(::VolumeType, cos_min, cos_max) = error("not implemented")


"""
    acceptance(cyl::Cylinder, cos_min=-1, cos_max=1)

Calculate the acceptance of a cylinder for a given range of cosine values.

## Arguments
- `cyl::Cylinder`: The cylinder object representing the detector.
- `cos_min::Float64`: The minimum value of the cosine.
- `cos_max::Float64`: The maximum value of the cosine.

## Returns
- `Float64`: The acceptance of the cylinder.

The acceptance is calculated by integrating the surface area of the cylinder over the range of cosine values.
"""
function acceptance(cyl::Cylinder, cos_min=-1, cos_max=1) 

    cap = π*cyl.radius^2
    sides = 2*cyl.radius*cyl.height

    return π*(cap*(cos_max*abs(cos_max)-cos_min*abs(cos_min)) +
                sides*(acos(cos_min) - acos(cos_max) - sqrt(1-cos_min^2)*cos_min + sqrt(1-cos_max^2)*cos_max));
end


sample_uniform_ray(::SurfaceType) = error("not defined")

"""
    sample_uniform_ray(c::CylinderSurface, cos_range)

    Sample intersection position and direction for rays from a uniform flux passing through the surface

    Code adapted from Jakob van Santen.
"""
function sample_uniform_ray(rng::AbstractRNG, c::CylinderSurface, cos_range)
    
    cyl = Cylinder(c)
    max_area = maximum_proj_area(cyl)
    if cos_range[1] == cos_range[2]
        uni_costheta = Dirac(cos_range[1])
    else
        uni_costheta = Uniform(cos_range...)
    end
    uni_maxarea = Uniform(0, max_area)
    
    cos_theta = 0.
    while true
        cos_theta = rand(rng, uni_costheta)
        if rand(rng, uni_maxarea) <= projected_area(cyl, cos_theta)
            break
        end
    end

    phi =  rand(rng)*2*π
    theta = acos(cos_theta)
    direction = sph_to_cart(acos(cos_theta), phi)

    a = sin(theta)*c.height/2.
    b = abs(cos(theta))*c.radius
    
    uni_x = Uniform(-c.radius, c.radius)
    uni_y = Uniform(-(a+b), a+b)
    x = 0.
    y = 0.
    while true
        x = rand(rng, uni_x)
        y = rand(rng, uni_y)

        if abs(y) <= (a + b*sqrt(1 - x^2/(c.radius^2)))
            break
        end
    end
    
    pos = SA[y, x, 0]
    pos =  (AngleAxis(phi, 0., 0., 1.) * AngleAxis(theta, 0., 1., 0.)) * pos .+ c.center

    isec = get_intersection(c, pos, direction)
    pos = pos .+ direction .* isec.first
    return pos, direction
end

sample_uniform_ray(c::CylinderSurface, cos_range) = sample_uniform_ray(Random.default_rng(), c, cos_range)


chord_length(::VolumeType, position, direction) = error("Not implemented")

function chord_length(v::Cylinder, position, direction) 
    isec = get_intersection(v, position, direction)
    return isec.second - isec.first
end


abstract type AngularDistribution end
abstract type HalfSphereAngularDistribution  <: AngularDistribution end
struct UniformAngularDistribution <: AngularDistribution end

struct LowerHalfSphere <: HalfSphereAngularDistribution end



StructTypes.StructType(::Type{UniformAngularDistribution}) = StructTypes.Struct()

function Base.rand(rng::AbstractRNG, ::UniformAngularDistribution)
    phi = rand(rng) * 2 * π
    theta = acos(2 * rand(rng) - 1)
    return sph_to_cart(theta, phi)
end

Base.rand(u::UniformAngularDistribution) = rand(default_rng(), u)

function Base.rand(rng::AbstractRNG, ::LowerHalfSphere)
    phi = rand(rng) * 2 * π
    theta = acos(rand(rng) - 1)
    return sph_to_cart(theta, phi)
end

Base.rand(sph::LowerHalfSphere) = rand(default_rng(), sph)


abstract type Injector end
struct VolumeInjector{
    V<:VolumeType,
    E<:UnivariateDistribution,
    A<:AngularDistribution,
    L<:UnivariateDistribution,
    T<:UnivariateDistribution} <: Injector
    volume::V
    e_dist::E
    type_dist::CategoricalSetDistribution
    angular_dist::A
    length_dist::L
    time_dist::T
end

StructTypes.StructType(::Type{VolumeInjector}) = StructTypes.Struct()

function Base.:(==)(a::VolumeInjector, b::VolumeInjector)
    return (
        (a.volume == b.volume) &&
        (a.e_dist == b.e_dist) &&
        (a.type_dist == b.type_dist) &&
        (a.angular_dist == b.angular_dist) &&
        (a.length_dist == b.length_dist) &&
        (a.time_dist == b.time_dist)
    )
end


function Base.rand(rng::AbstractRNG, inj::VolumeInjector)
    energy = rand(rng, inj.e_dist)
    ptype = rand(rng, inj.type_dist)
    length = rand(rng, inj.length_dist)
    time = rand(rng, inj.time_dist)
    pos = rand(rng, inj.volume)
    dir = rand(rng, inj.angular_dist)
    event = Event()
    event[:particles] = [Particle(pos, dir, time, energy, length, ptype)]

    return event

end

Base.rand(inj::VolumeInjector) = rand(Random.default_rng(), inj)


struct SurfaceInjector{
    S<:SurfaceType,
    E<:UnivariateDistribution,
    A<:HalfSphereAngularDistribution,
    L<:UnivariateDistribution,
    T<:UnivariateDistribution} <: Injector
    surface::S
    e_dist::E
    type_dist::CategoricalSetDistribution
    angular_dist::A
    length_dist::L
    time_dist::T
end

function Base.:(==)(a::SurfaceInjector, b::SurfaceInjector)
    return (
        (a.surface == b.surface) &&
        (a.e_dist == b.e_dist) &&
        (a.type_dist == b.type_dist) &&
        (a.angular_dist == b.angular_dist) &&
        (a.length_dist == b.length_dist) &&
        (a.time_dist == b.time_dist)
    )
end


function Base.rand(rng::AbstractRNG, inj::SurfaceInjector)
    pos = rand(rng, inj.surface)
    energy = rand(rng, inj.e_dist)
    ptype = rand(rng, inj.type_dist)
    length = rand(rng, inj.length_dist)
    time = rand(rng, inj.time_dist)

    # This draws a direction uniformly on a half sphere. Need to rotate z-axis of half sphere onto cylinder tangent plane

    pos, dir = sample_uniform_ray(rng, inj.surface, (-1., 1.))
    
    event = Event()
    event[:particles] = [Particle(pos, dir, time, energy, length, ptype)]
    return event

end

is_volume(::VolumeInjector) = true
is_surface(::SurfaceInjector) = true

struct LIInjector <: Injector
    states::DataFrame
    not_sampled::BitVector
end

StructTypes.StructType(::Type{LIInjector}) = StructTypes.Struct()

function LIInjector(fname::String; drop_starting=false, volume=nothing)
    if drop_starting && isnothing(volume)
        error("Provide volume to filter out starting events")
    end
    hdl = h5open(fname)

    final1 = []
    final2 = []
    initial = []
    one_weights = []
    flux_weights = []

    for inj in hdl
        push!(final1, DataFrame(inj["final_1"][:]))
        push!(final2,  DataFrame(inj["final_2"][:]))
        push!(initial, DataFrame(inj["initial"][:]))
        push!(one_weights, inj["one_weights"][:])
        push!(flux_weights, inj["flux_weights"][:])
    end
    close(hdl)

    final1 = reduce(vcat, final1)
    final2 = reduce(vcat, final2)
    initial = reduce(vcat, initial)
    one_weights = reduce(vcat, one_weights)
    flux_weights = reduce(vcat, flux_weights)
    

    final1.row_num = 1:nrow(final1)
    final2.row_num = 1:nrow(final2)
    initial.row_num = 1:nrow(initial)

    combined = innerjoin(final1, final2, on=:row_num, renamecols = "_final1" => "_final2")
    combined = innerjoin(combined, initial, on=:row_num, renamecols = "" => "_initial")
    combined[:, :one_weights] .= one_weights
    combined[:, :flux_weights] .= flux_weights

    if drop_starting
        positions = initial[:, :Position]
        not_in_volume = .!point_in_volume.(Ref(volume), positions)

        combined = combined[not_in_volume, :]
    end

    return LIInjector(combined, ones(Bool, nrow(combined)))
end

Base.length(inj::LIInjector) = nrow(inj.states)
Base.size(inj::LIInjector) = (nrow(inj.states),)

function _sample_event_from_li(inj::LIInjector, ix)
    ptype_f1 = ptype_for_code(inj.states[ix, :ParticleType_final1])
    
    if is_neutrino(ptype_f1)
        # NC interaction, return the cascade

        pos = SVector{3}(inj.states[ix, :Position_final2])
        dir_sph = SVector{2}(inj.states[ix, :Direction_final2])
        energy = inj.states[ix, :Energy_final2]
        ptype = PHadronShower
    else
        pos = SVector{3}(inj.states[ix, :Position_final1])
        dir_sph = SVector{2}(inj.states[ix, :Direction_final1])
        
        if particle_shape(ptype_f1) == Track()
            energy = inj.states[ix, :Energy_final1]
            ptype = ptype_f1
        else particle_shape(ptype_f1) == Cascade()
            # Sum energy of the hadronic cascade + lepton energy
            energy = inj.states[ix, :Energy_final1] + inj.states[ix, :Energy_final2]
            ptype = PHadronShower
        end
    end

    dir = sph_to_cart(dir_sph)
    p = Particle(pos, dir, 0., energy, -1., ptype)

    event = Event()
    event[:particles] = [p]
    event[:flux_weight] = inj.states[ix, :flux_weights]
    event[:one_weight] = inj.states[ix, :one_weights]
    event[:initial_energy] = inj.states[ix, :Energy_initial]
    event[:lifile_index] = ix

    return event
end


function Base.rand(rng::AbstractRNG, inj::LIInjector)
    if sum(inj.not_sampled) == 0
        error("Injector ran out of events")
    end
    valid_indices = (1:length(inj))[inj.not_sampled]
    ix = rand(rng, valid_indices)
    inj.not_sampled[ix] = false
    return _sample_event_from_li(inj, ix)
end

Base.rand(inj::LIInjector) = rand(Random.default_rng(), inj)
Base.iterate(inj::LIInjector) = (_sample_event_from_li(inj, 1), 1)
Base.iterate(inj::LIInjector, state) = state == length(inj) ? nothing : (_sample_event_from_li(inj, state+1), state+1)
end

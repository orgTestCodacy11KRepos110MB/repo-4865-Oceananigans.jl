module Biogeochemistry

using Oceananigans.Grids: Center, xnode, ynode, znode
using Oceananigans.Forcings: maybe_constant_field, DiscreteForcing
using Oceananigans.Advection: div_Uc, UpwindBiasedFifthOrder
using Oceananigans.Operators: identity1

import Oceananigans.Fields: location, CenterField
import Oceananigans.Forcings: regularize_forcing

#####
##### Generic fallbacks for biogeochemistry
#####

"""
Update tendencies.

Called at the end of calculate_tendencies!
"""
update_tendencies!(bgc, model) = nothing

"""
Update tracer tendencies.

Called at the end of calculate_tendencies!
"""
update_biogeochemical_state!(bgc, model) = nothing

@inline biogeochemical_drift_velocity(bgc, val_tracer_name) = nothing
@inline biogeochemical_advection_scheme(bgc, val_tracer_name) = nothing

#####
##### Default (discrete form) biogeochemical source
#####

abstract type AbstractBiogeochemistry end

@inline function biogeochemistry_rhs(i, j, k, grid, bgc, val_tracer_name, clock, fields)
    U_drift = biogeochemical_drift_velocity(bgc, val_tracer_name)
    scheme = biogeochemical_advection_scheme(bgc, val_tracer_name)
    src = biogeochemical_transition(i, j, k, grid, val_tracer_name, clock, fields)
    c = fields[val_tracer_name]
        
    return src + div_Uc(i, j, k, grid, scheme, U_drift, c)
end

@inline biogeochemical_transition(i, j, k, grid, bgc, val_tracer_name, clock, fields) =
    bgc(i, j, k, grid, val_tracer_name, clock, fields)

@inline (bgc::AbstractBiogeochemistry)(i, j, k, grid, val_tracer_name, clock, fields) = zero(grid)

#####
##### Continuous form biogeochemical source
#####
 
"""Return the biogeochemical forcing for `val_tracer_name` when model is called."""
abstract type AbstractContinuousFormBiogeochemistry <: AbstractBiogeochemistry end

@inline extract_biogeochemical_fields(i, j, k, grid, fields, names::NTuple{1}) =
    @inbounds (fields[names[1]][i, j, k],)

@inline extract_biogeochemical_fields(i, j, k, grid, fields, names::NTuple{2}) =
    @inbounds (fields[names[1]][i, j, k],
               fields[names[2]][i, j, k])

@inline extract_biogeochemical_fields(i, j, k, grid, fields, names::NTuple{N}) where N =
    @inbounds ntuple(n -> fields[names[n]][i, j, k], Val(N))

@inline function biogeochemical_transition(i, j, k, grid, bgc::AbstractContinuousFormBiogeochemistry,
                                           val_tracer_name, clock, fields)

    names_to_extract = tuple(required_biogeochemical_tracers(bgc)...,
                             required_biogeochemical_auxiliary_fields(bgc)...)

    fields_ijk = extract_biogeochemical_fields(i, j, k, grid, fields, names_to_extract)

    x = xnode(Center(), Center(), Center(), i, j, k, grid)
    y = ynode(Center(), Center(), Center(), i, j, k, grid)
    z = znode(Center(), Center(), Center(), i, j, k, grid)

    return bgc(val_tracer_name, x, y, z, clock.time, fields_ijk...)
end

@inline (bgc::AbstractContinuousFormBiogeochemistry)(val_tracer_name, x, y, z, t, fields...) = zero(x)

struct NoBiogeochemistry <: AbstractBiogeochemistry end

tracernames(tracers) = keys(tracers)
tracernames(tracers::Tuple) = tracers

@inline function all_fields_present(fields::NamedTuple, required_fields, grid)
    field_names = keys(fields)
    field_values = values(fields)

    for field_name in required_fields
        if field_name not in field_names
            push!(field_names, field_name)
            push!(field_values, CenterField(grid))
        end
    end

    return NamedTuple{field_names}(field_values)
end

@inline all_fields_present(fields::Tuple, required_fields, grid) = (fields..., required_fields...)

"""Ensure that `tracers` contains biogeochemical tracers and `auxiliary_fields` contains biogeochemical auxiliary fields (e.g. PAR)."""
@inline function validate_biogeochemistry(tracers, auxiliary_fields, bgc, grid)
    req_tracers = required_biogeochemical_tracers(bgc)
    tracers = all_fields_present(tracers, req_tracers, grid)

    req_auxiliary_fields = required_biogeochemical_auxiliary_fields(bgc)
    auxiliary_fields = all_fields_present(auxiliary_fields, req_auxiliary_fields, grid)
    
    return tracers, auxiliary_fields
end

required_biogeochemical_tracers(::NoBiogeochemistry) = ()
required_biogeochemical_auxiliary_fields(bgc::AbstractBiogeochemistry) = ()

"""
    SomethingBiogeochemistry <: AbstractBiogeochemistry

Sets up a tracer based biogeochemical model in a similar way to SeawaterBuoyancy.

Example
=======

@inline growth(x, y, z, t, P, μ₀, λ, m) = (μ₀ * exp(z / λ) - m) * P 

biogeochemistry = Biogeochemistry(tracers = :P, transitions = (; P=growth))
"""
struct Biogeochemistry{T, S, U, A, P} <: AbstractContinuousFormBiogeochemistry
    biogeochemical_tracers :: NTuple{N, Symbol} where N
    transitions :: T
    advection_schemes :: S
    drift_velocities :: U
    auxiliary_fields :: A
    parameters :: P
end

@inline required_biogeochemical_tracers(bgc::SomethingBiogeochemistry) = bgc.biogeochemical_tracers
@inline required_biogeochemical_auxiliary_fields(bgc::SomethingBiogeochemistry) = bgc.auxiliary_fields
@inline biogeochemical_drift_velocity(bgc::Biogeochemistry, val_tracer_name) = bgc.drift_velocities[val_tracer_name]
@inline biogeochemical_advection_scheme(bgc::Biogeochemistry, val_tracer_name) = bgc.advection_schemes[val_tracer_name]

@inline (bgc::Biogeochemistry)(::Val{name}, x, y, z, t, fields_ijk...) = 
    bgc.transitions[name](x, y, z, t, fields_ijk..., bgc.parameters...)

#=
function regularize_drift_velocities(drift_speeds)
    drift_velocities = []
    for w in values(drift_speeds)
        u, v, w = maybe_constant_field.((0.0, 0.0, - w))
        push!(drift_velocities, (; u, v, w))
    end

    return NamedTuple{keys(drift_speeds)}(drift_velocities)
end
=#

# we can't use the standard `ContinuousForcing` regularisation here because it requires all the tracers to be inplace to have the correct indices
struct ContinuousBiogeochemicalForcing
    func::Function
    parameters::NamedTuple
    field_dependencies::NTuple{N, Symbol} where N
end

DiscreteBiogeochemicalForcing = DiscreteForcing

ContinuousBiogeochemicalForcing(func; parameters=nothing, field_dependencies=()) = ContinuousBiogeochemicalForcing(func, parameters, field_dependencies)

function BiogeochemicalForcing(func; parameters=nothing, discrete_form=false, field_dependencies=())
    if discrete_form
        return DiscreteBiogeochemicalForcing(func, parameters)
    else
        return ContinuousBiogeochemicalForcing(func, parameters, field_dependencies)
    end
end

function regularize_biogeochemical_forcing(forcing::Function)
    return ContinuousBiogeochemicalForcing(forcing)
end

regularize_biogeochemical_forcing(forcing) = forcing

@inline getargs(fields, field_dependencies, i, j, k, grid, params::Nothing) = @inbounds identity1.(i, j, k, grid, fields[field_dependencies])
@inline getargs(fields, field_dependencies, i, j, k, grid, params) = @inbounds tuple(identity1.(i, j, k, grid, fields[field_dependencies])..., params)

@inline function (forcing::ContinuousBiogeochemicalForcing)(i, j, k, grid, clock, fields)
    args = getargs(fields, forcing.field_dependencies, i, j, k, grid, forcing.parameters)

    x = xnode(Center(), Center(), Center(), i, j, k, grid)
    y = ynode(Center(), Center(), Center(), i, j, k, grid)
    z = znode(Center(), Center(), Center(), i, j, k, grid)

    return forcing.func(x, y, z, clock.time, args...)
end

@inline function SomethingBiogeochemistry(tracers, transitions; advection_scheme=UpwindBiasedFifthOrder, drift_velocities=NamedTuple(), auxiliary_fields=())
    transitions = NamedTuple{keys(transitions)}([regularize_biogeochemical_forcing(transition) for transition in values(transitions)]) 
    drift_velocities = regularize_drift_velocities(drift_velocities)
    return SomethingBiogeochemistry(tracers, transitions, advection_scheme, drift_velocities, auxiliary_fields)
end

@inline function (bgc::SomethingBiogeochemistry)(i, j, k, grid, val_tracer_name::Val{tracer_name}, clock, fields) where tracer_name
    # there is probably a cleaner way todo this with multiple dispathc
    transition = bgc.transitions[tracer_name](i, j, k, grid, clock, fields)

    if tracer_name in keys(bgc.drift_velocities)
        drift = - div_Uc(i, j, k, grid, bgc.adv_scheme, bgc.drift_velocities[tracer_name], fields[tracer_name])
        return transition + drift
    else
        return transition
    end
end


end # module

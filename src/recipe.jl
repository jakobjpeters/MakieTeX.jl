
@recipe(TeXImg, tex) do scene
    merge(
        default_theme(scene),
        Attributes(
            color = AbstractPlotting.automatic,
            implant = true,
            dpi = 72.0,
            align = (:left, :center),
            textsize = 12, # in pt
            position = Point2f0(0)
        )
    )
end

function AbstractPlotting.convert_arguments(::Type{<: TeXImg}, x::AbstractString)
    return (CachedTeX(implant_math(x)),)
end

function AbstractPlotting.convert_arguments(::Type{<: TeXImg}, x::LaTeXString)
    if first(x) == "\$" && last(x) == "\$"
        return (CachedTeX(implant_math(x)),)
    else
        return (CachedTeX(implant_text(x)),)
    end
end

function AbstractPlotting.convert_arguments(::Type{<: TeXImg}, doc::TeXDocument)
    return (CachedTeX(doc),)
end

function AbstractPlotting.plot!(plot::T) where T <: TeXImg
    # image to draw
    # We always want to draw this at a 1:1 ratio, so increasing textsize or
    # changing dpi should rerender
    img = map(plot[1], plot.dpi, plot.textsize) do texdoc, dpi, textsize
        scale = textsize / 12
        rsvg2img(texdoc.handle, scale * dpi)
    end

    # Rect to draw in
    # This is mostly aligning
    xr = Node(0.0..1.0)
    yr = Node(0.0..1.0)
    lift(img, plot.position, plot.align) do img, pos, align
        halign, valign = align
        x, y = pos
        w, h = size(img)

        if halign == :left
            x -= 0
        elseif halign == :center
            x -= w / 2
        elseif halign == :right
            x -= w
        end

        if valign == :top
            y -= h
        elseif valign == :center
            y -= h / 2
        elseif valign == :bottom
            y -= 0
        end

        xr[] = x..x+w
        yr[] = y..y+h
        nothing
    end

    image!(plot, xr, yr, img)
end

function get_ink_extents(surf::CairoSurface)
    dims = zeros(Float64, 4)

    ccall(
        (:cairo_recording_surface_ink_extents, CairoMakie.LIB_CAIRO),
        Cvoid,
        (Ptr{Cvoid}, Ptr{Cdouble}, Ptr{Cdouble}, Ptr{Cdouble}, Ptr{Cdouble}),
        surf.ptr, Ref(dims, 1), Ref(dims, 2), Ref(dims, 3), Ref(dims, 4)
    )

    return dims
end

function CairoMakie.draw_plot(scene::Scene, screen::CairoMakie.CairoScreen, img::T) where T <: MakieTeX.TeXImg

    bbox = AbstractPlotting.boundingbox(img)

    ctx = screen.context
    tex = img[1][]
    halign, valign = img.align[]

    handle = svg2rsvg(tex.svg)
    dims = tex.raw_dims

    surf, rctx = rsvg2recordsurf(handle)
    x0, y0, w, h = get_ink_extents(surf)

    pos = CairoMakie.project_position(scene, img.position[], img.model[])
    scale = img.textsize[] / 12
    _w = scale * w; _h = scale * h
    scale_factor = CairoMakie.project_scale(scene, Vec2f0(_w, _h), img.model[])

    pos = if halign == :left
        pos
    elseif halign == :center
        pos .- (scale_factor[1] / 2, 0)
    elseif halign == :right
        pos .- (scale_factor[1], 0)
    end

    pos = if valign == :top
        pos .+ (0, scale_factor[2])
    elseif valign == :center
        pos .+ (0, scale_factor[2] / 2)
    elseif valign == :bottom
        pos
    end



    Cairo.save(ctx)
    Cairo.translate(
        ctx,
        pos[1],
        pos[2] - (h + y0) * scale_factor[2] / h
    )
    Cairo.scale(
        ctx,
        scale_factor[1] / w,
        scale_factor[2] / h
    )
    render_surface(ctx, surf)
    Cairo.restore(ctx)
end

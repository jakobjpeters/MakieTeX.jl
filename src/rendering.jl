const DVISVGM_PATH = Ref{String}()
const LIBGS_PATH = Ref{String}()

function dvisvg()
    if !isassigned(DVISVGM_PATH)
        if Sys.isunix()
           DVISVGM_PATH[] = readchomp(`which dvisvgm`)
       end
    end
    return DVISVGM_PATH[]
end


function libgs()
    if !isassigned(LIBGS_PATH) && !haskey(ENV, "LIBGS")
        if Sys.isapple()
           LIBGS_PATH[] = joinpath(readchomp(`brew --cellar ghostscript`), "9.56.1", "lib", "libgs.dylib.9.56")
       end
   elseif !isassigned(LIBGS_PATH) && haskey(ENV, "LIBGS")
        LIBGS_PATH[] = ENV["LIBGS"]
    end
    return LIBGS_PATH[]
end



function compile_latex(
        document::AbstractString;
        tex_engine = `lualatex`,
        options = `-file-line-error -halt-on-error`,
        format = "dvi",
        read_format = format
    )

    # First, we do some input checking.
    if !(format ∈ ("dvi", "pdf"))
        @error "Format must be either dvi or pdf; was $format"
    end
    formatcmd = ``
    if format == "dvi"
        if tex_engine==`lualatex`
            tex_engine=`dvilualatex`
        end
        # produce only dvi not pdf
        formatcmd = `-dvi -pdf-`
    else # format == "pdf"
        formatcmd = `-pdf`
    end

    # Unfortunately for us, Latexmk (which is required for any complex LaTeX doc)
    # does not like to compile straight to stdout, OR take in input from stdin;
    # it needs a file. We make a temporary directory for it to output to,
    # and create a file in there.
    return mktempdir() do dir
        cd(dir) do

            # First, create the tex file and write the document to it.
            touch("temp.tex")
            file = open("temp.tex", "w")
            print(file, document)
            close(file)

            # Now, we run the latexmk command in a pipeline so that we can redirect stdout and stderr to internal containers.
            # First we establish these pipelines:
            out = Pipe()
            err = Pipe()

            latex_cmd = `latexmk $options --shell-escape -latex=$tex_engine -cd -interaction=nonstopmode --output-format=$format $formatcmd temp.tex`

            latex_pipeline = pipeline(ignorestatus(latex_cmd), stdout=out, stderr=err)

            try
                latex = run(latex_pipeline)
                suc = success(latex)
                close(out.in)
                close(err.in)
                if !isfile("temp.$read_format")
                    println("Latex did not write temp.$(read_format)!")
                    println("Files in temp directory are:\n" * join(readdir(), ','))
                    printstyled("Stdout\n", bold=true)
                    println(read(out, String))
                    printstyled("Stderr\n", bold=true)
                    println(read(err, String))
                    return
                end
            finally
                return read(joinpath("temp.$read_format"), String)
            end
        end
    end
end


compile_latex(document::TeXDocument; kwargs...) = compile_latex(convert(String, document); kwargs...)

latex2dvi(args...; kwargs...) = compile_latex(args...; format = "dvi", kwargs...)
latex2pdf(args...; kwargs...) = compile_latex(args...; format = "pdf", kwargs...)

function dvi2svg(
        dvi::String;
        bbox = .2, # minimal bounding box
        options = ``
    )
    # dvisvgm will allow us to convert the DVI file into an SVG which
    # can be rendered by Rsvg.  In this case, we are able to provide
    # dvisvgm a DVI file from stdin, and receive a SVG string from
    # stdout.  This greatly simplifies the pipeline, and anyone with
    # a working TeX installation should have these utilities available.

    dvisvgm_cmd = Cmd(`$(dvisvg()) --bbox=$bbox --no-fonts --stdin --stdout $options`, env = ("LIBGS" => libgs(),))

    # We create an IO buffer to redirect stderr
    err = Pipe()

    dvisvgm = open(dvisvgm_cmd, "r+")

    redirect_stderr(err) do
        write(dvisvgm, dvi)
        close(dvisvgm.in)
    end

    return read(dvisvgm.out, String) # read the SVG in as a String


end

function pdf2svg(pdf::Vector{UInt8})
    pdftocairo = open(`pdftocairo -svg - -`, "r+")

    write(pdftocairo, pdf)

    close(pdftocairo.in)

    return read(pdftocairo.out, String)
end

# function dvi2png(dvi::Vector{UInt8}; dpi = 72.0, libgs = nothing)
#
#     # dvisvgm will allow us to convert the DVI file into an SVG which
#     # can be rendered by Rsvg.  In this case, we are able to provide
#     # dvisvgm a DVI file from stdin, and receive a SVG string from
#     # stdout.  This greatly simplifies the pipeline, and anyone with
#     # a working TeX installation should have these utilities available.
#     dvipng = open(`dvipng --bbox=$bbox $options --no-fonts  --stdin --stdout `, "r+")
#
#     write(dvipng, dvi)
#
#     close(dvipng.in)
#
#     return read(dvipng.out, String) # read the SVG in as a String
# end

function svg2img(svg::String, dpi = 72.0)

    # First, we instantiate an Rsvg handle, which holds a parsed representation of
    # the SVG.  Then, we set its DPI to the provided DPI (usually, 300 is good).
    handle = Rsvg.handle_new_from_data(svg)

    return rsvg2img(handle, dpi)
end

function rsvg2img(handle::Rsvg.RsvgHandle, dpi = 72.0)
    Rsvg.handle_set_dpi(handle, Float64(dpi))

    # We can find the final dimensions (in pixel units) of the Rsvg image.
    # Then, it's possible to store the image in a native Julia array,
    # which simplifies the process of rendering.
    d = Rsvg.handle_get_dimensions(handle)

    # Cairo does not draw "empty" pixels, so we need to fill here
    w, h = d.width, d.height
    img = fill(Colors.ARGB32(1,1,1,0), w, h)

    # Cairo allows you to use a Matrix of ARGB32, which simplifies rendering.
    cs = Cairo.CairoImageSurface(img)
    c = Cairo.CairoContext(cs)

    # Render the parsed SVG to a Cairo context
    Rsvg.handle_render_cairo(c, handle)

    # The image is rendered transposed, so we need to flip it.
    return rotr90(permutedims(img))
end

function svg2rsvg(svg::String, dpi = 72.0)
    handle = Rsvg.handle_new_from_data(svg)
    Rsvg.handle_set_dpi(handle, Float64(dpi))
    return handle
end

function rsvg2recordsurf(handle::Rsvg.RsvgHandle)
    surf = Cairo.CairoRecordingSurface()
    ctx  = Cairo.CairoContext(surf)
    Rsvg.handle_render_cairo(ctx, handle)
    return (surf, ctx)
end

function render_surface(ctx::CairoContext, surf)
    Cairo.save(ctx)

    Cairo.set_source(ctx, surf, 0.0, 0.0)

    Cairo.paint(ctx)

    Cairo.restore(ctx)
    return
end

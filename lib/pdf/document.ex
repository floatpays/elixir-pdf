defmodule Pdf.Document do
  defstruct objects: nil,
            info: nil,
            fonts: nil,
            current: nil,
            current_font: nil,
            current_font_size: 0,
            pages: [],
            opts: [],
            images: %{}

  import Pdf.Utils

  alias Pdf.{
    Dictionary,
    Fonts,
    RefTable,
    Trailer,
    Array,
    ObjectCollection,
    Page,
    Paper,
    Image
  }

  @header <<"%PDF-1.7\n%", 304, 345, 362, 345, 353, 247, 363, 240, 320, 304, 306, 10>>
  @header_size byte_size(@header)

  def new(opts \\ []) do
    {:ok, collection} = ObjectCollection.start_link()
    {:ok, fonts} = Fonts.start_link(collection)

    info =
      ObjectCollection.create_object(
        collection,
        Dictionary.new(%{"Creator" => "Elixir", "Producer" => "Elixir-PDF"})
      )

    document = %__MODULE__{objects: collection, fonts: fonts, info: info, opts: opts}
    add_page(document, opts)
  end

  @info_map %{
    title: "Title",
    producer: "Producer",
    creator: "Creator",
    created: "CreationDate",
    modified: "ModDate",
    keywords: "Keywords",
    author: "Author",
    subject: "Subject"
  }

  def put_info(document, info_list) when is_list(info_list) do
    info = ObjectCollection.get_object(document.objects, document.info)

    info =
      info_list
      |> Enum.reduce(info, fn {key, value}, info ->
        case @info_map[key] do
          nil ->
            raise ArgumentError, "Invalid info key #{inspect(key)}"

          info_key ->
            Dictionary.put(info, info_key, value)
        end
      end)

    ObjectCollection.update_object(document.objects, document.info, info)
    document
  end

  @info_map
  |> Enum.each(fn {key, _value} ->
    def put_info(document, unquote(key), value), do: put_info(document, [{unquote(key), value}])
  end)

  # Pass-through functions that update the current page
  [
    {:set_fill_color, quote(do: [color])},
    {:set_stroke_color, quote(do: [color])},
    {:set_line_width, quote(do: [width])},
    {:set_line_cap, quote(do: [style])},
    {:set_line_join, quote(do: [style])},
    {:rectangle, quote(do: [{x, y}, {w, h}])},
    {:line, quote(do: [{x, y}, {x2, y2}])},
    {:move_to, quote(do: [{x, y}])},
    {:line_append, quote(do: [{x, y}])},
    {:set_font, quote(do: [name, size, opts])},
    {:set_font_size, quote(do: [size])},
    {:set_text_leading, quote(do: [leading])},
    {:text_at, quote(do: [{x, y}, text, opts])},
    {:text_lines, quote(do: [{x, y}, lines, opts])},
    {:stroke, []},
    {:fill, []},
    {:move_down, quote(do: [amount])}
  ]
  |> Enum.map(fn {func_name, args} ->
    def unquote(func_name)(%__MODULE__{current: page} = document, unquote_splicing(args)) do
      page = Page.unquote(func_name)(page, unquote_splicing(args))
      %{document | current: page}
    end
  end)

  def text_at(document, xy, text), do: text_at(document, xy, text, [])

  def text_wrap(document, xy, wh, text), do: text_wrap(document, xy, wh, text, [])

  def text_wrap(%__MODULE__{current: page} = document, xy, wh, text, opts) do
    {page, remaining} = Page.text_wrap(page, xy, wh, text, opts)
    {%{document | current: page}, remaining}
  end

  def table(document, xy, wh, data), do: table(document, xy, wh, data, [])

  def table(%__MODULE__{current: page} = document, xy, wh, data, opts) do
    {page, remaining} = Page.table(page, xy, wh, data, opts)
    {%{document | current: page}, remaining}
  end

  def continue_table(document, xy, wh, data), do: continue_table(document, xy, wh, data, [])

  def continue_table(%__MODULE__{current: page} = document, xy, wh, data, opts) do
    {page, remaining} = Page.continue_table(page, xy, wh, data, opts)
    {%{document | current: page}, remaining}
  end

  def text_lines(document, xy, lines), do: text_lines(document, xy, lines, [])

  def add_image(%__MODULE__{current: page} = document, {x, y}, image_path, opts \\ []) do
    document = create_image(document, image_path)
    image = document.images[image_path]
    %{document | current: Page.add_image(page, {x, y}, image, opts)}
  end

  defp create_image(%{objects: objects, images: images} = document, image_path) do
    images =
      Map.put_new_lazy(images, image_path, fn ->
        image = Image.new(image_path)
        object = ObjectCollection.create_object(objects, image)
        name = n("I#{Kernel.map_size(images) + 1}")
        %{name: name, object: object, image: image}
      end)

    %{document | images: images}
  end

  def add_external_font(%{fonts: fonts} = document, path) do
    Fonts.add_external_font(fonts, path)
    document
  end

  def add_page(%__MODULE__{current: nil, fonts: fonts} = document, opts) do
    new_page = Page.new(Keyword.merge(opts, fonts: fonts))
    %{document | current: new_page}
  end

  def add_page(%__MODULE__{current: current_page, pages: pages} = document, opts) do
    add_page(%{document | current: nil, pages: [current_page | pages]}, opts)
  end

  def page_number(%__MODULE__{pages: pages}), do: length(pages) + 1

  def size(%__MODULE__{current: current_page}) do
    Page.size(current_page)
  end

  def cursor(%__MODULE__{current: current_page}) do
    Page.cursor(current_page)
  end

  def set_cursor(%__MODULE__{current: current_page} = document, y) do
    %{document | current: Page.set_cursor(current_page, y)}
  end

  def to_iolist(document) do
    pages = Enum.reverse([document.current | document.pages])
    proc_set = [n("PDF"), n("Text")]

    proc_set =
      if Kernel.map_size(document.images) > 0,
        do: [n("ImageB"), n("ImageC"), n("ImageI") | proc_set],
        else: proc_set

    resources =
      Dictionary.new(%{
        "Font" => font_dictionary(document.fonts),
        "ProcSet" => Array.new(proc_set)
      })

    resources =
      if Kernel.map_size(document.images) > 0 do
        Dictionary.put(resources, "XObject", xobject_dictionary(document.images))
      else
        resources
      end

    page_collection =
      Dictionary.new(%{
        "Type" => n("Pages"),
        "Count" => length(pages),
        "MediaBox" => Array.new(Paper.size(default_page_size(document))),
        "Resources" => resources
      })

    master_page = ObjectCollection.create_object(document.objects, page_collection)
    page_objects = pages_to_objects(document, pages, master_page)
    ObjectCollection.call(document.objects, master_page, :put, ["Kids", Array.new(page_objects)])

    catalogue =
      ObjectCollection.create_object(
        document.objects,
        Dictionary.new(%{"Type" => n("Catalog"), "Pages" => master_page})
      )

    objects = ObjectCollection.all(document.objects)

    {ref_table, offset} = RefTable.to_iolist(objects, @header_size)

    Pdf.Export.to_iolist([
      @header,
      objects,
      ref_table,
      Trailer.new(objects, offset, catalogue, document.info)
    ])
  end

  defp pages_to_objects(%__MODULE__{objects: objects} = document, pages, parent) do
    pages
    |> Enum.map(fn page ->
      page_object = ObjectCollection.create_object(objects, page)

      dictionary =
        Dictionary.new(%{
          "Type" => n("Page"),
          "Parent" => parent,
          "Contents" => page_object
        })

      dictionary =
        if page.size != default_page_size(document) do
          Dictionary.put(dictionary, "MediaBox", Array.new(Paper.size(page.size)))
        else
          dictionary
        end

      ObjectCollection.create_object(objects, dictionary)
    end)
  end

  defp font_dictionary(fonts) do
    fonts
    |> Fonts.get_fonts()
    |> Enum.reduce(%{}, fn {_name, %{name: name, object: reference}}, map ->
      Map.put(map, name, reference)
    end)
    |> Dictionary.new()
  end

  defp xobject_dictionary(images) do
    images
    |> Enum.reduce(%{}, fn {_name, %{name: name, object: reference}}, map ->
      Map.put(map, name, reference)
    end)
    |> Dictionary.new()
  end

  defp default_page_size(%__MODULE__{opts: opts}), do: Keyword.get(opts, :size, :a4)
end

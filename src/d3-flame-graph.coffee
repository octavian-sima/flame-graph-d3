d3 = window.d3
throw new Error("d3.js needs to be loaded") if not d3

d3.flameGraph = ->

  getClassAndMethodName = (fqdn) ->
    tokens = fqdn.split(".")
    tokens.slice(tokens.length - 2).join(".")

  # Return a vector (0.0 -> 1.0) that is a hash of the input string.
  # The hash is computed to favor early characters over later ones, so
  # that strings with similar starts have similar vectors. Only the first
  # 6 characters are considered.
  hash = (name) ->
    [result, maxHash, weight, mod] = [0, 0, 1, 10]
    name = getClassAndMethodName(name).slice(0, 6)
    for i in [0..(name.length-1)]
      result += weight * (name.charCodeAt(i) % mod)
      maxHash += weight * (mod - 1)
      weight *= 0.7
    if maxHash > 0 then result / maxHash else result

  addFillerNodes = (node) ->
    # TODO: if there are no fillers this can be expensive as it's called often
    children = node.children
    return node if not children
    return node if children.filter((child) -> child.filler).length > 0
    childSum = children.reduce ((sum, child) -> sum + child.value), 0
    if childSum < node.value
      children.push
        value: node.value - childSum
        filler: true
    children.forEach(addFillerNodes)
    node

  # augments each node in the tree with the maximum distance
  # it is from a terminal node
  addMaxDepth = (node) ->
    computeDepth = (node) ->
      return 0 if not node # TODO: this should not be needed
      return 1 if not node.children
      return node.maxDepth if node.maxDepth

      max = node.children
        .map(computeDepth)
        .reduce ((max, depth) -> if depth > max then depth else max), 0

      node.maxDepth = max + 1
      return node.maxDepth
    computeDepth(node)
    node

  partitionData = (data) ->
    d3.layout
      .partition()
      .sort((a,b) ->
        return 1  if a.filler # move fillers to the right
        return -1 if b.filler # move fillers to the right
        a.name.localeCompare(b.name))
      .nodes(data)

  class FlameGraph
    constructor: () ->
      @_generateAccessors([
        'size',
        'margin',
        'cellHeight',
        'zoomEnabled',
        'tooltip'
        'color'])
      @_ancestors = []

      # defaults
      @_size        = [1200, 800]
      @_cellHeight  = 10
      @_margin      = { top: 0, right: 0, bottom: 0, left: 0 }
      @_color       = (d) ->
        val = hash(d.name)
        r = 200 + Math.round(55 * val)
        g = 0 + Math.round(230 * (1 - val))
        b = 0 + Math.round(55 * (1 - val))
        "rgb(#{r}, #{g}, #{b})"
      @_tooltipEnabled = true
      @_zoomEnabled = true

    data: (data) ->
      return @_data if not data
      @original = data if not @original
      @_data = partitionData(addMaxDepth(addFillerNodes(data)))
      @

    zoom: (node) ->
      throw new Error("Zoom is disabled!") if not @zoomEnabled()
      if node in @_ancestors
        @_ancestors = @_ancestors.slice(0, @_ancestors.indexOf(node))
      else
        @_ancestors.push(@data()[0])
      @data(node).render(@_selector)
      @

    width: () -> @size()[0] - (@margin().left + @margin().right)

    height: () -> @size()[1] - (@margin().top + @margin().bottom)

    label: (d) ->
      return "" if not d?.name
      label = getClassAndMethodName(d.name)
      label.substr(0, Math.round(@x(d.dx) / (@cellHeight() / 10 * 4)))

    select: (regex, onlyVisible = true) ->
      if onlyVisible
        return @container.selectAll('.node').filter((d) -> regex.test(d.name))
      else
        # re-partition original and filter that
        result = partitionData(@original).filter((d) -> regex.test(d.name))
        return result

    render: (selector) ->
      if not (@_selector or selector)
        throw new Error("The container's selector needs to be provided before rendering")
      console.time('render')
      # refresh container
      @_selector = selector if selector
      d3.select(selector).select('svg').remove()
      @container = d3.select(selector)
        .append('svg')
          .attr('class', 'flame-graph')
          .attr('width', @size()[0])
          .attr('height', @size()[1])
        .append('g')
          .attr('transform', "translate(#{@margin().left}, #{@margin().top})")

      @maxCells = Math.floor(@height() / @cellHeight())
      @maxDepth = @data()[0].maxDepth

      @fontSize = (@cellHeight() / 10) * 0.4

      @x = d3.scale.linear()
        .domain([0, d3.max(@data(), (d) -> d.x + d.dx)])
        .range([0, @width()])
      @y = d3.scale.quantize()
        .domain([d3.max(@data(), (d) -> d.y), 0])
        .range(d3.range(@maxDepth)
          .map((cell) =>  (cell - @maxDepth + @maxCells - @_ancestors.length) * @cellHeight()))

      containers = @container
        .selectAll('.node')
        .data(@data().filter((d) =>
          @x(d.dx) > 0.1 and @y(d.y) >= 0 and not d.filler))
        .enter()
          .append('g').attr('class', (d, idx) -> if idx == 0 then 'root node' else 'node')

      @_renderNodes containers,
        x: (d) => @x(d.x)
        y: (d) => @y(d.y)
        width: (d) => @x(d.dx)
        height: (d) => @cellHeight()
        text: (d) => @label(d) if d.name and @x(d.dx) > 40

      console.timeEnd('render')
      console.log("Rendered #{@container.selectAll('.node')[0]?.length} elements")
      @_renderAncestors()._enableNavigation()   if @zoomEnabled()
      @_renderTooltip()                         if @tooltip()
      @

    _renderNodes: (containers, attrs) ->
      containers.append('rect')
        .attr('width', attrs.width)
        .attr('height', @cellHeight())
        .attr('x', attrs.x)
        .attr('y', attrs.y)
        .attr('fill', (d) => @color()(d))

      containers.append('text')
        .attr('class', 'label')
        .attr('dy', "#{@fontSize / 2}em")
        .attr('x', (d) => attrs.x(d) + 2)
        .attr('y', (d, idx) => attrs.y(d, idx) + @cellHeight() / 2)
        .style('font-size', "#{@fontSize}em")
        .text(attrs.text)
      # overlaying a transparent rectangle to capture events
      # TODO: maybe there's a smarter way to do this?
      containers.append('rect')
        .attr('class', 'overlay')
        .attr('width', attrs.width)
        .attr('height', @cellHeight())
        .attr('x', attrs.x)
        .attr('y', attrs.y)
      @

    _renderTooltip: () ->
      @tip = d3.tip()
        .attr('class', 'd3-tip')
        .html(@tooltip())
        .direction (d) =>
          return 'w' if @x(d.x) + @x(d.dx) / 2 > @width() - 100
          return 'e' if @x(d.x) + @x(d.dx) / 2 < 100
          return 's' # otherwise
        .offset (d) =>
          x = @x(d.x) + @x(d.dx) / 2
          xOffset = Math.max(Math.ceil(@x(d.dx) / 2), 5)
          yOffset = Math.ceil(@cellHeight() / 2)
          return [0, -xOffset] if @width() - 100 < x
          return [0,  xOffset] if x < 100
          return [ yOffset, 0]

      @container.call(@tip)
      @container
        .selectAll('.node')
          .on 'mouseover', @tip.show
          .on 'mouseout', @tip.hide
      @

    _renderAncestors: () ->
      ancestorData = @_ancestors.map((ancestor, idx) ->
        { name: ancestor.name, value: idx })
      ancestors = @container
        .selectAll('.ancestor')
        .data(ancestorData)

      containers = ancestors
        .enter()
        .append('g')
          .attr('class', 'ancestor')

      @_renderNodes containers,
        x: (d) => 0
        y: (d, idx) => @height() - ((idx + 1) * @cellHeight())
        width: @width()
        height: @cellHeight()
        text: (d) => "↩ #{getClassAndMethodName(d.name)}"
      @

    _enableNavigation: () ->
      @container
        .selectAll('.node')
        .on 'click', (d, idx) =>
          d3.event.stopPropagation()
          @zoom(d) if idx > 0
      @container
        .selectAll('.ancestor')
        .on 'click', (d, idx) =>
          d3.event.stopPropagation()
          @zoom(@_ancestors[idx])
      @

    _generateAccessors: (accessors) ->
      for accessor in accessors
        @[accessor] = do (accessor) ->
          (newValue) ->
            return @["_#{accessor}"] if not arguments.length
            @["_#{accessor}"] = newValue
            return @

  return new FlameGraph()
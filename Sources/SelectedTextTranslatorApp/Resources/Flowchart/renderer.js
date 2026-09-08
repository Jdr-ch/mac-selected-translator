/* Local SVG templates. Only typed text/data crosses the native bridge, never model-supplied markup. */
(() => {
  "use strict";
  // Detached exports need an explicit namespace to remain valid SVG documents outside this page.
  const NS = "http://www.w3.org/2000/svg";
  // Measurement and exported text must share a font stack; no remote font download delays layout.
  const FONT = '"PingFang SC", "Helvetica Neue", "Microsoft YaHei", sans-serif';
  const context = document.createElement("canvas").getContext("2d");
  const words = new Intl.Segmenter("zh", { granularity: "word" });
  const graphemes = new Intl.Segmenter("zh", { granularity: "grapheme" });
  const stage = document.getElementById("stage");
  const viewport = document.getElementById("viewport");
  let assets;
  let currentSVG;
  let serialized = "";
  let zoom = null;
  let boxes = [];
  // Raster outputs belong to the current SVG revision and are discarded on edits/style changes.
  const pngCache = new Map();

  /** Create trusted geometry or text with DOM APIs; user strings are never interpreted as markup. */
  function node(tag, attributes = {}, parent) {
    const element = document.createElementNS(NS, tag);
    for (const [name, value] of Object.entries(attributes)) element.setAttribute(name, String(value));
    if (parent) parent.appendChild(element);
    return element;
  }

  /** Wrap by language-aware word boundaries, splitting oversized words at grapheme boundaries. */
  function wrap(text, width, size, weight = 400) {
    context.font = `${weight} ${size}px ${FONT}`;
    const lines = [];
    for (const paragraph of String(text).split("\n")) {
      let line = "";
      for (const { segment } of words.segment(paragraph)) {
        if (context.measureText(line + segment).width <= width) {
          line += segment;
          continue;
        }
        if (line.trim()) lines.push(line.trimEnd());
        line = "";
        for (const { segment: character } of graphemes.segment(segment.trimStart())) {
          // Long identifiers have no word boundaries; break them without splitting Unicode characters.
          if (line && context.measureText(line + character).width > width) {
            lines.push(line);
            line = "";
          }
          line += character;
        }
      }
      lines.push(line.trimEnd());
    }
    return lines;
  }

  /** Keep measured text blocks available to both layout and the focused geometry checks. */
  function textBlock(parent, text, x, y, width, size, color, weight = 400, align = "left", label = "") {
    const lines = wrap(text, width, size, weight);
    const lineHeight = Math.ceil(size * 1.4);
    const element = node("text", {
      x: align === "center" ? x + width / 2 : align === "right" ? x + width : x,
      y: y + size, fill: color, "font-size": size, "font-weight": weight,
      "font-family": FONT, "letter-spacing": 0,
      "text-anchor": align === "center" ? "middle" : align === "right" ? "end" : "start",
      "data-text-block": label,
    }, parent);
    lines.forEach((line, index) => {
      const span = node("tspan", { x: element.getAttribute("x"), dy: index ? lineHeight : 0 }, element);
      span.textContent = line;
    });
    const height = lines.length * lineHeight;
    boxes.push({ label, x, y, width, height });
    return height;
  }

  /** Clone a bundled Lucide icon, preserving its standard line geometry in standalone exports. */
  function icon(parent, name, x, y, size, color) {
    const source = assets.icons[name] || assets.icons.settings;
    const parsed = new DOMParser().parseFromString(source, "image/svg+xml").documentElement;
    const svg = node("svg", { x, y, width: size, height: size, viewBox: "0 0 24 24",
      fill: "none", stroke: color, "stroke-width": 1.6, "stroke-linecap": "round", "stroke-linejoin": "round" }, parent);
    for (const child of parsed.children) svg.appendChild(document.importNode(child, true));
  }

  /** Store reusable local paint servers so neither preview nor export needs raster assets. */
  function gradient(defs, id, top, bottom) {
    const gradient = node("linearGradient", { id, x1: 0, y1: 0, x2: 0, y2: 1 }, defs);
    node("stop", { offset: 0, "stop-color": top }, gradient);
    node("stop", { offset: 1, "stop-color": bottom }, gradient);
  }

  /** Horizontal card dimensions follow the longest wrapped title/description in this document. */
  function horizontal(diagram) {
    const cardWidth = 252;
    const gap = 102;
    const margin = 72;
    // Reserve whole title lines before positioning descriptions; values are SVG user-space pixels.
    const titleHeights = diagram.steps.map(step => wrap(step.title, cardWidth - 40, 28, 600).length * 40);
    // Descriptions use their own smaller line height rather than the title's typography.
    const descriptionHeights = diagram.steps.map(step => wrap(step.description, cardWidth - 40, 19).length * 27);
    // All cards adopt the largest required height, including icon space and bottom padding.
    const cardHeight = Math.max(220, ...titleHeights.map((height, i) => 110 + height + descriptionHeights[i]));
    const width = Math.max(1000, margin * 2 + cardWidth * diagram.steps.length + gap * (diagram.steps.length - 1));
    const svg = node("svg", { xmlns: NS, width, role: "img" });
    const defs = node("defs", {}, svg);
    gradient(defs, "background", "#101827", "#182638");
    gradient(defs, "artifact", "#287df0", "#2051aa");
    gradient(defs, "process", "#f2a14c", "#d57732");
    gradient(defs, "result", "#20aa80", "#14755b");
    const background = node("rect", { width, fill: "url(#background)" }, svg);
    const titleHeight = textBlock(svg, diagram.title, margin, 44, width - margin * 2, 38, "#f4f7fc", 700, "left", "heading");
    const subtitleHeight = textBlock(svg, diagram.subtitle, margin, 54 + titleHeight, width - margin * 2, 21, "#adbbce", 400, "left", "subtitle");
    const cardY = 98 + titleHeight + subtitleHeight;
    const startX = (width - cardWidth * diagram.steps.length - gap * (diagram.steps.length - 1)) / 2;
    diagram.steps.forEach((step, index) => {
      const x = startX + index * (cardWidth + gap);
      const group = node("g", { "data-step-index": index }, svg);
      node("rect", { x, y: cardY, width: cardWidth, height: cardHeight, rx: 8,
        fill: `url(#${step.kind})`, "data-card": index }, group);
      icon(group, step.icon_id, x + 22, cardY + 24, 38, "#ffffff");
      textBlock(group, String(index + 1).padStart(2, "0"), x + cardWidth - 65, cardY + 25, 42, 16, "#ffffff", 500, "right", `number-${index}`);
      const titleHeight = textBlock(group, step.title, x + 20, cardY + 84, cardWidth - 40, 28, "#ffffff", 600, "left", `title-${index}`);
      textBlock(group, step.description, x + 20, cardY + 98 + titleHeight, cardWidth - 40, 19, "#f1f4f8", 400, "left", `description-${index}`);
      if (index < diagram.steps.length - 1) {
        const from = x + cardWidth + 12;
        const to = x + cardWidth + gap - 14;
        const cy = cardY + cardHeight / 2;
        node("path", { d: `M ${from} ${cy} H ${to - 10}`, stroke: "#9badc4", "stroke-width": 3, fill: "none" }, svg);
        node("path", { d: `M ${to - 12} ${cy - 7} L ${to} ${cy} L ${to - 12} ${cy + 7} Z`, fill: "#9badc4" }, svg);
        const labelHeight = wrap(step.next_label, gap - 14, 15).length * 21;
        textBlock(svg, step.next_label, x + cardWidth + 7, cy - labelHeight - 15, gap - 14, 15, "#bdc9db", 400, "center", `edge-${index}`);
      }
    });
    const height = cardY + cardHeight + 68;
    svg.setAttribute("height", height);
    svg.setAttribute("viewBox", `0 0 ${width} ${height}`);
    background.setAttribute("height", height);
    return svg;
  }

  /** Reuse only trusted staircase geometry; IDs are made unique for every repeated stage. */
  function staircaseGeometry(parent, templateID, prefix, x, y, scaleY, palette, mirrored = false) {
    const source = assets.staircase.querySelector(`[id="${templateID}"]`);
    const clone = document.importNode(source, true);
    clone.setAttribute("transform", `translate(${x},${y}) scale(2,${scaleY})`);
    const idMap = new Map();
    for (const element of [clone, ...clone.querySelectorAll("[id]")]) {
      const oldID = element.id;
      idMap.set(oldID, `${prefix}-${oldID}`);
      element.id = `${prefix}-${oldID}`;
    }
    for (const element of clone.querySelectorAll("*")) {
      for (const attribute of Array.from(element.attributes)) {
        let value = attribute.value;
        for (const [oldID, newID] of idMap) value = value.replaceAll(`url(#${oldID})`, `url(#${newID})`);
        element.setAttribute(attribute.name, value);
      }
    }
    clone.querySelectorAll("stop").forEach((stop, index) => stop.setAttribute("stop-color", palette[index % 2]));
    clone.querySelectorAll("feDropShadow").forEach(shadow => {
      shadow.setAttribute("flood-color", palette[1]);
      shadow.setAttribute("flood-opacity", "0.18");
      shadow.setAttribute("stdDeviation", "3");
    });
    if (mirrored) {
      // The reference ends on the right; reflect its closed base when an odd-length flow ends left.
      const reflection = node("g", { transform: "translate(148.92,0) scale(-1,1)" });
      while (clone.firstChild) reflection.appendChild(clone.firstChild);
      clone.appendChild(reflection);
    }
    parent.appendChild(clone);
  }

  /** Alternating side labels grow the row pitch, keeping the connected reference geometry intact. */
  function staircase(diagram) {
    const width = 1360;
    const textWidth = 300;
    const palettes = [["#dea7f2", "#a64fce"], ["#72d7ec", "#1996bd"], ["#9cc0fc", "#477cd0"], ["#f4e56b", "#bca717"]];
    const svg = node("svg", { xmlns: NS, width, role: "img" });
    const defs = node("defs", {}, svg);
    const background = node("rect", { width, fill: "#ffffff" }, svg);
    const titleHeight = textBlock(svg, diagram.title, 60, 38, width - 120, 34, "#30343b", 650, "center", "heading");
    const subtitleHeight = textBlock(svg, diagram.subtitle, 100, 54 + titleHeight, width - 200, 20, "#777f88", 400, "center", "subtitle");
    // Labels on each side appear every second step; their tallest block determines safe spacing.
    const panelHeights = diagram.steps.map(step => wrap(step.title, textWidth, 25, 600).length * 35 + wrap(step.description, textWidth, 19).length * 27 + 14);
    const pitch = Math.max(136, Math.ceil((Math.max(...panelHeights) + 40) / 2));
    const sy = pitch / 68;
    const top = 100 + titleHeight + subtitleHeight;
    let bottom = top;
    for (let row = 0; row < diagram.steps.length; row += 1) {
      const index = diagram.steps.length - row - 1;
      const step = diagram.steps[index];
      const isLeft = row % 2 === 0;
      const palette = palettes[index % palettes.length];
      const rootY = row === 0 ? top : top + 26.626 * sy + (row - 1) * pitch;
      const centerY = rootY + (row === 0 ? 22 : 63) * sy;
      const group = node("g", { "data-step-index": index }, svg);
      const isBase = row === diagram.steps.length - 1 && row > 0;
      const templateID = row === 0 ? "gr-4-taiijie" : isBase ? "gr-1-taiijie" : isLeft ? "gr-2-taiijie" : "gr-3-taiijie";
      staircaseGeometry(group, templateID, `stage-${index}`, isLeft ? 500 : 644, rootY, sy, palette, isBase && isLeft);
      const circleX = isLeft ? 410 : 990;
      const textX = isLeft ? 60 : 1040;
      const textY = centerY - 29;
      gradient(defs, `badge-${index}`, palette[0], palette[1]);
      node("circle", { cx: circleX, cy: centerY, r: 27, fill: `url(#badge-${index})` }, group);
      icon(group, step.icon_id, circleX - 14, centerY - 14, 28, "#ffffff");
      const titleHeight = textBlock(group, step.title, textX, textY, textWidth, 25, palette[1], 600,
        isLeft ? "right" : "left", `title-${index}`);
      const descriptionHeight = textBlock(group, step.description, textX, textY + titleHeight + 12,
        textWidth, 19, "#555c65", 400, isLeft ? "right" : "left", `description-${index}`);
      const platformCenterX = isLeft ? 610 : 830;
      textBlock(group, String(index + 1).padStart(2, "0"), platformCenterX - 24, centerY - 18, 48, 22, "#ffffff", 600, "center", `number-${index}`);
      bottom = Math.max(bottom, rootY + (row === 0 ? 58 : 98) * sy + 35, textY + titleHeight + 12 + descriptionHeight + 45);
    }
    const height = Math.ceil(bottom + 25);
    svg.setAttribute("height", height);
    svg.setAttribute("viewBox", `0 0 ${width} ${height}`);
    background.setAttribute("height", height);
    return svg;
  }

  /** Fit affects the preview only; exports always use the original SVG viewBox. */
  function fit() {
    if (!currentSVG) return;
    const width = Number(currentSVG.getAttribute("width"));
    const height = Number(currentSVG.getAttribute("height"));
    const scale = zoom === null ? Math.min((viewport.clientWidth - 48) / width, (viewport.clientHeight - 48) / height) : zoom;
    stage.style.width = `${width * Math.max(0.02, scale)}px`;
    stage.style.height = `${height * Math.max(0.02, scale)}px`;
  }

  /** Initialize once from packaged resources supplied by native code, with no file/network fetches. */
  function initialize(resources) {
    assets = { icons: resources.icons, staircase: new DOMParser().parseFromString(resources.staircase, "image/svg+xml") };
  }

  /** Replace one document revision atomically, invalidate raster caches, and measure local layout time. */
  function render(diagram, style) {
    const started = performance.now();
    if (!assets) throw Error("绘图资源尚未加载。");
    boxes = [];
    // A new document has no seed diagram; clearing also prevents stale image exports.
    document.getElementById("empty-state").hidden = diagram.steps.length > 0;
    if (!diagram.steps.length) {
      currentSVG = null;
      serialized = "";
      pngCache.clear();
      stage.replaceChildren();
      stage.removeAttribute("style");
      return { render_ms: performance.now() - started, width: 0, height: 0 };
    }
    currentSVG = style === "staircase" ? staircase(diagram) : horizontal(diagram);
    const title = node("title", {}, currentSVG);
    title.textContent = diagram.title;
    serialized = new XMLSerializer().serializeToString(currentSVG);
    pngCache.clear();
    stage.replaceChildren(currentSVG);
    fit();
    return { render_ms: performance.now() - started, width: Number(currentSVG.getAttribute("width")), height: Number(currentSVG.getAttribute("height")) };
  }

  /** Rasterize the exact serialized SVG, independent of preview zoom and native window dimensions. */
  async function exportPNG(longEdge = 2400) {
    if (!serialized) throw Error("请先生成流程图。");
    if (pngCache.has(longEdge)) return pngCache.get(longEdge);
    const source = serialized;
    const width = Number(currentSVG.getAttribute("width"));
    const height = Number(currentSVG.getAttribute("height"));
    const scale = longEdge / Math.max(width, height);
    const canvas = document.createElement("canvas");
    canvas.width = Math.max(1, Math.round(width * scale));
    canvas.height = Math.max(1, Math.round(height * scale));
    const url = URL.createObjectURL(new Blob([source], { type: "image/svg+xml;charset=utf-8" }));
    try {
      const image = new Image();
      image.src = url;
      await image.decode();
      canvas.getContext("2d").drawImage(image, 0, 0, canvas.width, canvas.height);
      const result = { data: canvas.toDataURL("image/png").split(",")[1], width: canvas.width, height: canvas.height };
      if (source === serialized) pngCache.set(longEdge, result);
      return result;
    } finally {
      URL.revokeObjectURL(url);
    }
  }

  window.FlowchartRenderer = {
    initialize, render, exportPNG,
    serialize: () => serialized,
    setZoom: value => { zoom = value; fit(); },
    textBoxes: () => boxes,
  };
  new ResizeObserver(fit).observe(viewport);
})();

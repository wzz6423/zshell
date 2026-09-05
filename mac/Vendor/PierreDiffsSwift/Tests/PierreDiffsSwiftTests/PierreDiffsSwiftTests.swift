import Foundation
import Testing
@testable import PierreDiffsSwift

@Test func defaultRenderOptionsPreserveBridgeDefaults() {
  let options = PierreDiffInput.Options(
    theme: .init(dark: "pierre-dark", light: "pierre-light"),
    diffStyle: "split",
    overflow: "scroll",
    enableLineSelection: true
  )

  #expect(options.theme.dark == "pierre-dark")
  #expect(options.theme.light == "pierre-light")
  #expect(options.diffIndicators == "bars")
  #expect(options.hunkSeparators == "line-info")
  #expect(options.lineDiffType == "word-alt")
  #expect(options.disableLineNumbers == false)
  #expect(options.disableFileHeader == false)
  #expect(options.disableBackground == false)
  #expect(options.expandUnchanged == false)
  #expect(options.stickyHeader == false)
  #expect(options.collapsedContextThreshold == nil)
  #expect(options.maxLineDiffLength == nil)
  #expect(options.expansionLineCount == nil)
  #expect(options.tokenizeMaxLength == nil)
  #expect(options.tokenizeMaxLineLength == nil)
  #expect(options.font == .default)
  #expect(options.font.family == PierreDiffFont.defaultCodeFamily)
  #expect(options.font.size == "12px")
  #expect(options.font.lineHeight == "1.5")
  #expect(options.font.headerFamily == PierreDiffFont.defaultHeaderFamily)
  #expect(options.font.tabSize == 2)
}

@Test func renderOptionsEncodeForJavaScriptBridge() throws {
  let renderOptions = PierreDiffRenderOptions(
    theme: .pierreSoft,
    font: PierreDiffFont(
      family: "JetBrains Mono, Menlo, monospace",
      sizePoints: 13,
      lineHeight: 1.6,
      headerFamily: "SF Pro Text, system-ui, sans-serif",
      tabSize: 4
    ),
    diffIndicators: .classic,
    hunkSeparators: .metadata,
    lineDiffType: .char,
    disableLineNumbers: true,
    disableFileHeader: true,
    disableBackground: true,
    expandUnchanged: true,
    collapsedContextThreshold: 24,
    maxLineDiffLength: 4_096,
    expansionLineCount: 12,
    tokenizeMaxLength: 120_000,
    tokenizeMaxLineLength: 2_000,
    stickyHeader: true
  )
  let diffResult = DiffResult(
    filePath: "Sources/Example.swift",
    fileName: "Example.swift",
    original: "let value = 1\n",
    updated: "let value = 2\n"
  )

  let input = PierreDiffInput.from(
    diffResult: diffResult,
    diffStyle: .unified,
    overflowMode: .wrap,
    renderOptions: renderOptions
  )
  let data = try JSONEncoder().encode(input)
  let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  let options = try #require(object["options"] as? [String: Any])
  let theme = try #require(options["theme"] as? [String: Any])
  let font = try #require(options["font"] as? [String: Any])

  #expect(theme["dark"] as? String == "pierre-dark-soft")
  #expect(theme["light"] as? String == "pierre-light-soft")
  #expect(options["diffStyle"] as? String == "unified")
  #expect(options["overflow"] as? String == "wrap")
  #expect(options["diffIndicators"] as? String == "classic")
  #expect(options["hunkSeparators"] as? String == "metadata")
  #expect(options["lineDiffType"] as? String == "char")
  #expect(options["disableLineNumbers"] as? Bool == true)
  #expect(options["disableFileHeader"] as? Bool == true)
  #expect(options["disableBackground"] as? Bool == true)
  #expect(options["expandUnchanged"] as? Bool == true)
  #expect(options["collapsedContextThreshold"] as? Int == 24)
  #expect(options["maxLineDiffLength"] as? Int == 4_096)
  #expect(options["expansionLineCount"] as? Int == 12)
  #expect(options["tokenizeMaxLength"] as? Int == 120_000)
  #expect(options["tokenizeMaxLineLength"] as? Int == 2_000)
  #expect(options["stickyHeader"] as? Bool == true)
  #expect(font["family"] as? String == "JetBrains Mono, Menlo, monospace")
  #expect(font["size"] as? String == "13px")
  #expect(font["lineHeight"] as? String == "1.6")
  #expect(font["headerFamily"] as? String == "SF Pro Text, system-ui, sans-serif")
  #expect(font["tabSize"] as? Int == 4)
}

@Test func fontPointsConvenienceFormatsCSSValues() {
  let font = PierreDiffFont(family: "Menlo", sizePoints: 14.5, lineHeight: 1.25, tabSize: 0)
  #expect(font.family == "Menlo")
  #expect(font.size == "14.5px")
  #expect(font.lineHeight == "1.25")
  #expect(font.tabSize == 1)
  #expect(font.faces.isEmpty)
}

@Test func bundledFontFaceEncodesBase64ForBridge() throws {
  // Minimal valid-ish TTF-ish payload for encoding tests (not a real font).
  let fontBytes = Data([0x00, 0x01, 0x00, 0x00, 0xFF, 0xAB, 0xCD])
  let face = PierreDiffFontFace(
    family: "JetBrains Mono",
    data: fontBytes,
    format: .truetype,
    weight: "400",
    style: "normal"
  )
  let font = PierreDiffFont.bundled(
    familyName: "JetBrains Mono",
    faces: [face],
    sizePoints: 13,
    tabSize: 4
  )
  let renderOptions = PierreDiffRenderOptions(font: font)
  let input = PierreDiffInput.from(
    diffResult: DiffResult(
      filePath: "a.swift",
      fileName: "a.swift",
      original: "a\n",
      updated: "b\n"
    ),
    renderOptions: renderOptions
  )

  let data = try JSONEncoder().encode(input)
  let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  let options = try #require(object["options"] as? [String: Any])
  let encodedFont = try #require(options["font"] as? [String: Any])
  let faces = try #require(encodedFont["faces"] as? [[String: Any]])
  let encodedFace = try #require(faces.first)

  #expect(encodedFont["family"] as? String == "'JetBrains Mono', \(PierreDiffFont.defaultCodeFamily)")
  #expect(faces.count == 1)
  #expect(encodedFace["family"] as? String == "JetBrains Mono")
  #expect(encodedFace["data"] as? String == fontBytes.base64EncodedString())
  #expect(encodedFace["format"] as? String == "truetype")
  #expect(encodedFace["weight"] as? String == "400")
  #expect(encodedFace["style"] as? String == "normal")
}

@Test func fontFormatInfersFromExtension() {
  #expect(PierreDiffFontFormat.infer(fromPathExtension: "ttf") == .truetype)
  #expect(PierreDiffFontFormat.infer(fromPathExtension: "OTF") == .opentype)
  #expect(PierreDiffFontFormat.infer(fromPathExtension: "woff2") == .woff2)
  #expect(PierreDiffFontFormat.infer(fromPathExtension: "txt") == nil)
  #expect(PierreDiffFontFormat.truetype.mimeType == "font/ttf")
  #expect(PierreDiffFontFormat.woff2.mimeType == "font/woff2")
}

@Test func missingBundledFontResourceThrows() {
  #expect(throws: PierreDiffFontFaceError.self) {
    _ = try PierreDiffFontFace(
      family: "Missing",
      resource: "DefinitelyNotARealFontResource_xyz",
      extension: "ttf",
      bundle: .module
    )
  }
}

@Test func bridgeScriptDecodesBase64BytesAsUTF8() throws {
  // Regression test for egoist/kero#16: atob() alone yields a Latin-1 binary
  // string, so multi-byte UTF-8 (CJK, emoji, accents) turned into mojibake.
  // The script must re-decode the atob bytes as UTF-8 before JSON.parse.
  let payload = ["contents": "测试中文 diff 内容 🚀 café"]
  let base64 = try JSONEncoder().encode(payload).base64EncodedString()
  let script = DiffWebViewCoordinator.bridgeScript(method: "renderDiff", base64String: base64)

  #expect(script.contains("atob('\(base64)')"))
  #expect(script.contains("Uint8Array.from"))
  #expect(script.contains("new TextDecoder('utf-8')"))
  #expect(script.contains("window.pierreBridge.renderDiff(input)"))
  // JSON.parse must consume the UTF-8 decoded string, not the raw atob output.
  #expect(!script.contains("JSON.parse(atob"))
  let decodeIndex = try #require(script.range(of: "TextDecoder('utf-8')")?.lowerBound)
  let parseIndex = try #require(script.range(of: "JSON.parse")?.lowerBound)
  #expect(decodeIndex < parseIndex)
}

@Test func annotationBridgePreservesScrollWithoutForcedRerender() throws {
  let html = DiffHTMLTemplate.generateHTML()
  let setAnnotationsRange = try #require(html.range(of: "setAnnotations"))
  let removeAnnotationsRange = try #require(
    html[setAnnotationsRange.upperBound...].range(of: "removeAnnotations")
  )
  let setAnnotationsBlock = html[setAnnotationsRange.lowerBound..<removeAnnotationsRange.lowerBound]

  #expect(html.contains("scrollTop"))
  #expect(html.contains("scrollLeft"))
  #expect(setAnnotationsBlock.contains("preventEmit"))
  #expect(setAnnotationsBlock.contains(".render(") || setAnnotationsBlock.contains(".render({"))
  #expect(!setAnnotationsBlock.contains(".rerender()"))
}

@Test func fontBridgeAppliesCSSCustomProperties() throws {
  let html = DiffHTMLTemplate.generateHTML()
  // Minified bundles rename local functions; assert on stable bridge/CSS strings.
  #expect(html.contains("setFont"))
  #expect(html.contains("--diffs-font-family"))
  #expect(html.contains("--diffs-font-size"))
  #expect(html.contains("--diffs-line-height"))
  #expect(html.contains("--diffs-header-font-family"))
  #expect(html.contains("--diffs-tab-size"))
  #expect(html.contains("ui-monospace"))
  #expect(html.contains("pierreBridge"))
  // Bundled @font-face injection markers (stable strings survive minify)
  #expect(html.contains("pierre-font-faces"))
  #expect(html.contains("@font-face"))
  #expect(html.contains("font/ttf"))
  #expect(html.contains("font-display:swap") || html.contains("font-display: swap"))
}

@Test func multiFileBridgeIsExposedByTheBundle() throws {
  let html = DiffHTMLTemplate.generateHTML()
  // Minified bundles rename locals; assert on the stable bridge method names
  // and the upstream CodeView APIs the multi-file surface depends on.
  #expect(html.contains("renderFiles"))
  #expect(html.contains("scrollToFile"))
  #expect(html.contains("setItems"))
  #expect(html.contains("scrollTo"))
  #expect(html.contains("stickyHeaders"))
  #expect(html.contains("itemMetrics"))
  #expect(html.contains("fileEditChanged"))
  #expect(html.contains("fileEditCompleted"))
}

@Test func multiFileInputEncodesFilesAndOptions() throws {
  let files = [
    PierreDiffFile(
      id: "src/app.swift",
      name: "src/app.swift",
      oldName: "src/old.swift",
      oldContents: "let x = 1",
      newContents: "let x = 2",
      isEditable: true
    ),
    PierreDiffFile.note(id: "logo.png", name: "logo.png", "Binary file not shown"),
  ]
  let input = PierreMultiDiffInput(
    files: files,
    options: PierreDiffInput.Options(
      theme: .init(.pierre),
      themeType: "dark",
      diffStyle: "unified",
      overflow: "scroll",
      enableLineSelection: true
    )
  )

  let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(input))
  let root = try #require(json as? [String: Any])
  let encodedFiles = try #require(root["files"] as? [[String: Any]])
  #expect(encodedFiles.count == 2)
  #expect(encodedFiles[0]["id"] as? String == "src/app.swift")
  #expect(encodedFiles[0]["oldName"] as? String == "src/old.swift")
  #expect(encodedFiles[0]["newContents"] as? String == "let x = 2")
  #expect(encodedFiles[0]["isEditable"] as? Bool == true)
  #expect(encodedFiles[0]["note"] == nil)
  #expect(encodedFiles[1]["note"] as? String == "Binary file not shown")
  #expect(encodedFiles[1]["isEditable"] as? Bool == false)
  let options = try #require(root["options"] as? [String: Any])
  #expect(options["diffStyle"] as? String == "unified")
  #expect(options["themeType"] as? String == "dark")
}

@Test func scrollRequestEncodesAlignmentAndBehavior() throws {
  let instant = PierreScrollToFileInput(PierreDiffScrollRequest(fileID: "a.swift"))
  #expect(instant.id == "a.swift")
  #expect(instant.align == "start")
  #expect(instant.behavior == "instant")

  let animated = PierreScrollToFileInput(
    PierreDiffScrollRequest(fileID: "b.swift", alignment: .center, animated: true)
  )
  #expect(animated.align == "center")
  #expect(animated.behavior == "smooth")

  // The token only exists to re-trigger an otherwise identical request.
  #expect(
    PierreDiffScrollRequest(fileID: "a.swift", token: 1)
      != PierreDiffScrollRequest(fileID: "a.swift", token: 2)
  )
}

@Test func multiFileBundleShipsBlobBackedHighlightWorkers() throws {
  // Regression test: syntax tokenization ran on the main thread, so
  // scrolling a virtualized multi-file diff stalled for as long as it took to
  // highlight each newly mounted file. Highlighting has to happen in workers,
  // and they can only be started from a blob — the page is loaded with
  // loadHTMLString(baseURL: nil) and has no URL to load a worker script from.
  let html = DiffHTMLTemplate.generateHTML()
  #expect(html.contains("workerFactory"))
  #expect(html.contains("new Worker("))
  #expect(html.contains("createObjectURL"))
  #expect(html.contains("primeDiffHighlightCache"))
  // The worker bundle itself must be inlined, not referenced by URL.
  #expect(html.contains("createHighlighterCore") || html.contains("shiki"))
  #expect(!html.contains("worker-portable.js\""))
}

import 'dart:ffi' as ffi;
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:ffi/ffi.dart';
import 'package:pdfium_dart/pdfium_dart.dart' as pdfium;
import 'package:pdfrx/pdfrx.dart';

import 'score_pdf_document.dart';

bool _initialized = false;

Future<ScorePdfDocument> openScorePdf(Uint8List bytes) async {
  if (!_initialized) {
    pdfrxFlutterInitialize();
    _initialized = true;
  }

  final document = await PdfDocument.openData(
    Uint8List.fromList(bytes),
    sourceName: 'barlink-score.pdf',
  );
  return _PdfiumScoreDocument(document);
}

pdfium.PDFium? _pdfiumModule;

/// pdfrx가 이미 불러 둔 PDFium과 같은 라이브러리.
pdfium.PDFium get _pdfium =>
    _pdfiumModule ??= pdfium.getPdfium(modulePath: Pdfrx.pdfiumModulePath);

class _PdfiumScoreDocument extends ScorePdfDocument {
  final PdfDocument _document;

  _PdfiumScoreDocument(this._document);

  @override
  int get pagesCount => _document.pages.length;

  @override
  Future<double> pageAspectRatio(int pageIndex) async {
    final page = _document.pages[pageIndex];
    return page.width / page.height;
  }

  @override
  Future<Uint8List?> renderPage(
    int pageIndex, {
    double scale = 2,
  }) async {
    final page = _document.pages[pageIndex];
    final rendered = await page.render(
      fullWidth: page.width * scale,
      fullHeight: page.height * scale,
      backgroundColor: 0xFFFFFFFF,
    );
    if (rendered == null) return null;

    try {
      final image = await rendered.createImage();
      try {
        final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
        return byteData?.buffer.asUint8List();
      } finally {
        image.dispose();
      }
    } finally {
      rendered.dispose();
    }
  }

  @override
  Future<ScorePdfPageText> extractPageText(int pageIndex) async {
    final page = _document.pages[pageIndex];
    final text = await page.loadStructuredText();
    return ScorePdfPageText(
      fullText: text.fullText,
      fragments: text.fragments
          .where((fragment) => fragment.text.trim().isNotEmpty)
          .map((fragment) {
        final bounds = fragment.bounds;
        return ScorePdfTextFragment(
          text: fragment.text,
          left: (bounds.left / page.width).clamp(0.0, 1.0),
          top: ((page.height - bounds.top) / page.height).clamp(0.0, 1.0),
          right: (bounds.right / page.width).clamp(0.0, 1.0),
          bottom: ((page.height - bounds.bottom) / page.height).clamp(0.0, 1.0),
        );
      }).toList(growable: false),
      characters: <ScorePdfTextFragment>[
        for (final fragment in text.fragments)
          for (int index = 0;
              index < fragment.text.length && index < fragment.charRects.length;
              index++)
            if (fragment.text[index].trim().isNotEmpty)
              ScorePdfTextFragment(
                text: fragment.text[index],
                left: (fragment.charRects[index].left / page.width)
                    .clamp(0.0, 1.0),
                top: ((page.height - fragment.charRects[index].top) /
                        page.height)
                    .clamp(0.0, 1.0),
                right: (fragment.charRects[index].right / page.width)
                    .clamp(0.0, 1.0),
                bottom: ((page.height - fragment.charRects[index].bottom) /
                        page.height)
                    .clamp(0.0, 1.0),
              ),
      ],
    );
  }

  @override
  Future<List<List<double>>> extractVerticalLines(int pageIndex) async {
    try {
      // pdfrx의 PDFium 작업을 잠시 멈추고 같은 문서 핸들로 선 객체를 읽는다.
      return await _document.useNativeDocumentHandle(
          (int handle) => _verticalLines(handle, pageIndex));
    } catch (_) {
      return const <List<double>>[];
    }
  }

  @override
  Future<void> close() => _document.dispose();
}

/// PDF 변환 행렬 [a b c d e f]: (x, y) → (ax + cy + e, bx + dy + f).
List<double> _compose(List<double> outer, List<double> inner) => <double>[
      outer[0] * inner[0] + outer[2] * inner[1],
      outer[1] * inner[0] + outer[3] * inner[1],
      outer[0] * inner[2] + outer[2] * inner[3],
      outer[1] * inner[2] + outer[3] * inner[3],
      outer[0] * inner[4] + outer[2] * inner[5] + outer[4],
      outer[1] * inner[4] + outer[3] * inner[5] + outer[5],
    ];

List<List<double>> _verticalLines(int handle, int pageIndex) {
  final pdfium.PDFium lib = _pdfium;
  final pdfium.FPDF_DOCUMENT doc = pdfium.FPDF_DOCUMENT.fromAddress(handle);
  final pdfium.FPDF_PAGE page = lib.FPDF_LoadPage(doc, pageIndex);
  if (page == ffi.nullptr) return const <List<double>>[];
  final Arena arena = Arena();
  try {
    final double width = lib.FPDF_GetPageWidthF(page);
    final double height = lib.FPDF_GetPageHeightF(page);
    final ffi.Pointer<pdfium.FS_MATRIX> m = arena<pdfium.FS_MATRIX>();
    final ffi.Pointer<ffi.Float> px = arena<ffi.Float>(), py = arena<ffi.Float>();
    final ffi.Pointer<ffi.Float> stroke = arena<ffi.Float>();
    final List<List<double>> out = <List<double>>[];
    const List<double> identity = <double>[1, 0, 0, 1, 0, 0];

    void add(double x, double y0, double y1, double w) {
      out.add(<double>[
        x / width,
        (height - math.max(y0, y1)) / height,
        (height - math.min(y0, y1)) / height,
        w / width,
      ]);
    }

    void visit(pdfium.FPDF_PAGEOBJECT obj, List<double> parent) {
      final List<double> own = lib.FPDFPageObj_GetMatrix(obj, m) != 0
          ? <double>[m.ref.a, m.ref.b, m.ref.c, m.ref.d, m.ref.e, m.ref.f]
          : identity;
      final List<double> t = _compose(parent, own);
      final int type = lib.FPDFPageObj_GetType(obj);
      if (type == pdfium.FPDF_PAGEOBJ_FORM) {
        final int n = lib.FPDFFormObj_CountObjects(obj);
        for (int i = 0; i < n; i++) {
          visit(lib.FPDFFormObj_GetObject(obj, i), t);
        }
        return;
      }
      if (type != pdfium.FPDF_PAGEOBJ_PATH) return;
      final double scale = math.sqrt((t[0] * t[3] - t[1] * t[2]).abs());
      final double lineWidth =
          lib.FPDFPageObj_GetStrokeWidth(obj, stroke) != 0 ? stroke.value * scale : 0;
      final int count = lib.FPDFPath_CountSegments(obj);
      final List<(double, double, int)> points = <(double, double, int)>[];
      for (int i = 0; i < count; i++) {
        final pdfium.FPDF_PATHSEGMENT seg = lib.FPDFPath_GetPathSegment(obj, i);
        if (lib.FPDFPathSegment_GetPoint(seg, px, py) == 0) continue;
        final double x = px.value, y = py.value;
        points.add((
          t[0] * x + t[2] * y + t[4],
          t[1] * x + t[3] * y + t[5],
          lib.FPDFPathSegment_GetType(seg),
        ));
      }
      if (points.length < 2) return;
      // 굵은 마디선을 가는 직사각형(채움)으로 그리는 경우.
      final double minX = points.map((p) => p.$1).reduce(math.min);
      final double maxX = points.map((p) => p.$1).reduce(math.max);
      final double minY = points.map((p) => p.$2).reduce(math.min);
      final double maxY = points.map((p) => p.$2).reduce(math.max);
      if (points.length >= 4 && maxX - minX > 0.3 && maxX - minX < 4 && maxY - minY > 2) {
        add((minX + maxX) / 2, minY, maxY, maxX - minX);
        return;
      }
      for (int i = 1; i < points.length; i++) {
        final (double x0, double y0, _) = points[i - 1];
        final (double x1, double y1, int kind) = points[i];
        if (kind != pdfium.FPDF_SEGMENT_LINETO) continue;
        if ((x1 - x0).abs() < 0.3 && (y1 - y0).abs() > 2) add((x0 + x1) / 2, y0, y1, lineWidth);
      }
    }

    final int n = lib.FPDFPage_CountObjects(page);
    for (int i = 0; i < n; i++) {
      visit(lib.FPDFPage_GetObject(page, i), identity);
    }
    return out;
  } finally {
    arena.releaseAll();
    lib.FPDF_ClosePage(page);
  }
}

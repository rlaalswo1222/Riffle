import 'dart:typed_data';

import 'package:pdfx/pdfx.dart';

import 'score_pdf_document.dart';

Future<ScorePdfDocument> openScorePdf(Uint8List bytes) async {
  final document = await PdfDocument.openData(Uint8List.fromList(bytes));
  return _WebScorePdfDocument(document);
}

class _WebScorePdfDocument extends ScorePdfDocument {
  final PdfDocument _document;

  _WebScorePdfDocument(this._document);

  @override
  int get pagesCount => _document.pagesCount;

  @override
  Future<double> pageAspectRatio(int pageIndex) async {
    final page = await _document.getPage(pageIndex + 1);
    try {
      return page.width / page.height;
    } finally {
      await page.close();
    }
  }

  @override
  Future<Uint8List?> renderPage(
    int pageIndex, {
    double scale = 2,
  }) async {
    final page = await _document.getPage(pageIndex + 1);
    try {
      final image = await page.render(
        width: page.width * scale,
        height: page.height * scale,
        format: PdfPageImageFormat.jpeg,
        backgroundColor: '#ffffff',
      );
      return image?.bytes;
    } finally {
      await page.close();
    }
  }

  @override
  Future<ScorePdfPageText> extractPageText(int pageIndex) async =>
      ScorePdfPageText.empty;

  @override
  Future<void> close() => _document.close();
}

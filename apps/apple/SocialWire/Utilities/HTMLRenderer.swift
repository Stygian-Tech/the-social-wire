import Foundation

enum HTMLRenderer {
    static func wrappedHTML(_ html: String) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src https: data:; style-src 'unsafe-inline'; font-src data:;">
        <style>
          body {
            font: -apple-system-body;
            color: CanvasText;
            background: transparent;
            line-height: 1.58;
            padding: 0 18px 32px;
            margin: 0;
            overflow-wrap: break-word;
          }
          h1, h2, h3 { line-height: 1.2; }
          a { color: LinkText; }
          img, video { max-width: 100%; height: auto; border-radius: 8px; }
          pre { overflow-x: auto; white-space: pre-wrap; }
          blockquote { border-left: 3px solid #8e8e93; margin-left: 0; padding-left: 14px; color: #8e8e93; }
        </style>
        </head>
        <body>\(html)</body>
        </html>
        """
    }
}

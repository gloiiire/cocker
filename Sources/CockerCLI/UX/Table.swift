import Foundation

// Cocker UX charter §5 — unified table renderer. Single source of truth
// for ps, images, network ls, volume ls, etc. Docker-style : no borders,
// bold/dim header, empty-state hint, per-cell color overrides, automatic
// column widths.

public extension UX {
    enum Alignment: Sendable { case left, right }

    struct Table: Sendable {
        public struct Column: Sendable {
            public let header: String
            public let align: Alignment
            public let color: Color
            public let minWidth: Int
            public let maxWidth: Int?

            public init(
                _ header: String,
                align: Alignment = .left,
                color: Color = .default,
                minWidth: Int = 0,
                maxWidth: Int? = nil
            ) {
                self.header = header
                self.align = align
                self.color = color
                self.minWidth = minWidth
                self.maxWidth = maxWidth
            }
        }

        public struct Cell: Sendable {
            public let text: String
            public let color: Color?     // nil = inherit column color
            public init(_ text: String, color: Color? = nil) {
                self.text = text; self.color = color
            }
        }

        public struct Row: Sendable {
            public let cells: [Cell]
            public init(_ cells: [Cell]) { self.cells = cells }
            public init(_ texts: [String]) { self.cells = texts.map { Cell($0) } }
        }

        public let columns: [Column]
        public let rows: [Row]
        public let emptyMessage: String?  // nil = print bare header only

        public init(columns: [Column], rows: [Row], emptyMessage: String? = nil) {
            self.columns = columns
            self.rows = rows
            self.emptyMessage = emptyMessage
        }

        public func render() -> String {
            if rows.isEmpty, let msg = emptyMessage {
                return " " + UX.TTY.paint(msg, .dim, [.italic])
            }

            // Compute column widths : max(header, longest cell, minWidth),
            // capped by maxWidth if set. Color codes don't count toward width.
            var widths = columns.map { col in max(col.header.count, col.minWidth) }
            for row in rows {
                for (i, cell) in row.cells.prefix(columns.count).enumerated() {
                    let w = cell.text.count
                    let capped = columns[i].maxWidth.map { min(w, $0) } ?? w
                    if capped > widths[i] { widths[i] = capped }
                }
            }

            var lines: [String] = []

            // Header — bold + dim.
            let header = zip(columns, widths).map { (col, w) -> String in
                let padded = padCell(col.header, width: w, align: col.align)
                return UX.TTY.paint(padded, .dim, [.bold])
            }.joined(separator: "   ")
            lines.append(header)

            for row in rows {
                let line = zip(row.cells.prefix(widths.count), 0..<widths.count).map { (cell, i) -> String in
                    let col = columns[i]
                    let truncated = truncate(cell.text, max: widths[i])
                    let padded = padCell(truncated, width: widths[i], align: col.align)
                    let effectiveColor = cell.color ?? col.color
                    return UX.TTY.paint(padded, effectiveColor)
                }.joined(separator: "   ")
                lines.append(line)
            }

            return lines.joined(separator: "\n")
        }

        private func padCell(_ text: String, width: Int, align: Alignment) -> String {
            if text.count >= width { return text }
            let pad = String(repeating: " ", count: width - text.count)
            return align == .left ? text + pad : pad + text
        }

        private func truncate(_ text: String, max: Int) -> String {
            guard text.count > max else { return text }
            if max <= 3 { return String(text.prefix(max)) }
            return String(text.prefix(max - 1)) + "…"
        }
    }
}

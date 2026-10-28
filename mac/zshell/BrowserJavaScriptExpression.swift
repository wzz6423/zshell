import Foundation
import TreeSitter
import TreeSitterJavaScript

enum BrowserJavaScriptExpression {
    /// 只提取完整表达式，不按分号切割，也不改变多语句的 completion 语义。
    static func source(from text: String) -> String? {
        guard let parser = ts_parser_new() else { return nil }
        defer { ts_parser_delete(parser) }
        guard ts_parser_set_language(parser, tree_sitter_javascript()) else { return nil }
        let bytes = Array(text.utf8)
        guard let tree = text.withCString({ ts_parser_parse_string(parser, nil, $0, UInt32(bytes.count)) }) else { return nil }
        defer { ts_tree_delete(tree) }
        let root = ts_tree_root_node(tree)
        guard !ts_node_has_error(root) else { return nil }
        func children(_ node: TSNode) -> [TSNode] {
            (0..<ts_node_named_child_count(node)).map { ts_node_named_child(node, $0) }.filter {
                let type = String(cString: ts_node_type($0))
                return type != "comment" && type != "empty_statement"
            }
        }
        let statements = children(root)
        guard statements.count == 1, let statement = statements.first,
              String(cString: ts_node_type(statement)) == "expression_statement" else { return nil }
        let expressions = children(statement)
        guard expressions.count == 1, let expression = expressions.first else { return nil }
        let start = Int(ts_node_start_byte(expression))
        let end = Int(ts_node_end_byte(expression))
        guard start < end, end <= bytes.count else { return nil }
        return String(decoding: bytes[start..<end], as: UTF8.self)
    }
}

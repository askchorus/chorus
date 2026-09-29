import Foundation

/// The prompt behind "Compare", modelled on the multi-model setups known to work — Karpathy's
/// llm-council and Together AI's Mixture-of-Agents. The answers go in anonymized as [A], [B]…;
/// the comparing model is told to judge them critically instead of restating them, and to lead
/// with the best answer it can put together. Anonymized because a model rates its own writing
/// higher, and the one comparing is often also one of the answerers (DeepSeek comparing a
/// DeepSeek panel's answer). The sheet shows the comparison with the real names put back.
enum SummaryPrompt {
    /// "[A]" → "ChatGPT".
    typealias Names = [String: String]

    static func label(_ i: Int) -> String {
        i < 26 ? "[" + String(Character(UnicodeScalar(UInt8(65 + i)))) + "]" : "[\(i + 1)]"
    }

    static func build(question q: String, answers: [(name: String, text: String)],
                      chinese: Bool) -> (prompt: String, names: Names) {
        var names: Names = [:]
        var parts: [String] = []
        for (i, a) in answers.enumerated() {
            names[label(i)] = a.name
            parts.append(label(i) + "\n" + a.text)
        }
        let joined = parts.joined(separator: "\n\n———\n\n")
        let labels = answers.indices.map(label).joined(separator: chinese ? "、" : ", ")
        let n = answers.count
        let prompt = chinese ? """
        下面是 \(n) 个 AI 对\(q.isEmpty ? "同一个问题" : "问题「\(q)」")的回答，分别标为 \(labels)，不告诉你是哪家写的。请用中文把它们综合成一份对比，按这个顺序写：

        **结论**
        先直接回答这个问题：综合各家说对的部分，给出你认为最好的答案，几句话说清楚。

        **共识**
        各家都同意的要点，简短列出。

        **分歧与判断**
        每个分歧点一小段：各家怎么说，谁更可能对、为什么。拿不准就直说，并说明还需要什么信息才能判断。

        **各家独到之处**
        某一家提到、别家没提、值得留意的内容。

        规则：
        - 只按内容判断，不看写得长短、语气多笃定。你自己也可能是其中一家，不要偏袒任何一份。
        - 提到某一份时只写它的标签，比如 [A]，不要写"回答A"。
        - 某份如果拒答、报错或明显没写完，用一句话注明，不要当成一种观点。
        - 问题如果没有标准答案（创意、起名、开放讨论），不要硬找共识和分歧：在「结论」里挑出最好的几个点子并说明理由。
        - 哪一部分没有内容就整个省略。
        - 小标题用 **加粗** 单独一行，要点用 - 开头。不要用 markdown 表格（竖线 | 那种），展示窗口不支持，会显示成乱码。

        \(joined)
        """ : """
        Below are \(n) AI answers to \(q.isEmpty ? "the same question" : "the question “\(q)”"), labeled \(labels); you aren't told which AI wrote which. Combine them into one comparison, in English, in this order:

        **Bottom line**
        Answer the question directly first: pull together what the answers get right and give what you judge to be the best answer, in a few sentences.

        **Where they agree**
        The points they share, briefly.

        **Where they differ**
        One short section per disagreement: what each says, which is more likely right, and why. If you can't tell, say so, and say what would settle it.

        **Worth keeping**
        Anything one answer adds that the others miss and that matters.

        Rules:
        - Judge on substance only, not on length or how confident an answer sounds. You may be one of these AIs yourself; don't favor any answer.
        - Refer to an answer only by its label, like [A], not "Answer A".
        - If an answer refuses, errors out or is clearly cut off, note that in one line instead of treating it as a position.
        - If the question has no single right answer (creative work, naming, open discussion), don't force agreements and disagreements: in the bottom line, pick the strongest ideas and say why.
        - Leave out any section with nothing in it.
        - Put each heading on its own line in **bold**, and start points with -. Do not use markdown tables (the pipe | kind): the viewer can't render them and they come out garbled.

        \(joined)
        """
        return (prompt, names)
    }

    /// Puts the real names back: "[A]" → "ChatGPT". Also the full-width brackets a model
    /// writing Chinese tends to use (［A］, 【A】). Anything else in brackets is left alone.
    static func reveal(_ text: String, names: Names) -> String {
        var out = text
        for (label, name) in names {
            let key = label.dropFirst().dropLast()
            // Full-width ［ ］ written as escapes: they're only matched, never shown, so they
            // needn't be in the UI font's subset (build-app.sh checks string literals for that).
            for form in ["[\(key)]", "\u{FF3B}\(key)\u{FF3D}", "【\(key)】"] {
                out = out.replacingOccurrences(of: form, with: name)
            }
        }
        return out
    }
}

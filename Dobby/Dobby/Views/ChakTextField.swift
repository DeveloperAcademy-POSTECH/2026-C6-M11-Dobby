import SwiftUI

struct ChakTextField: View {
    let label: String
    @Binding var text: String
    let placeholder: String
    var isRequired = false
    var errorMessage: String? = nil

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ChakTextFieldLabel(label: label, isRequired: isRequired)
            ChakTextFieldEditor(
                text: $text,
                placeholder: placeholder,
                isFocused: $isFocused,
                showsError: errorMessage != nil
            )

            if let errorMessage {
                Text(errorMessage)
                    .font(.custom("Pretendard-Medium", fixedSize: 12))
                    .tracking(-0.12)
                    .foregroundStyle(Color(.accentsRed))
                    .accessibilityIdentifier("chak-text-field.error")
            }
        }
    }
}

private struct ChakTextFieldLabel: View {
    let label: String
    let isRequired: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(label)
                .font(.custom("Pretendard-Medium", fixedSize: 18))
                .tracking(-0.18)
                .foregroundStyle(Color(.exportCloseIcon))

            if isRequired {
                Text("*")
                    .font(.system(size: 17, weight: .semibold))
                    .tracking(-0.43)
                    .foregroundStyle(Color(.brandMain))
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label + (isRequired ? ", 필수" : ""))
    }
}

private struct ChakTextFieldEditor: View {
    @Binding var text: String
    let placeholder: String
    var isFocused: FocusState<Bool>.Binding
    let showsError: Bool

    var body: some View {
        TextField(
            "",
            text: $text,
            prompt: Text(placeholder)
                .foregroundStyle(Color(red: 191 / 255, green: 191 / 255, blue: 191 / 255))
        )
        .font(.custom("Pretendard-Regular", fixedSize: 16))
        .tracking(-0.16)
        .focused(isFocused)
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(minHeight: 56)
        .background(Color(.brandNeutral100), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            if showsError || isFocused.wrappedValue {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(borderColor, lineWidth: 1)
            }
        }
    }

    private var borderColor: Color {
        if showsError {
            return Color(.accentsRed)
        }
        return Color(red: 122 / 255, green: 117 / 255, blue: 110 / 255)
    }
}

#Preview("기본") {
    @Previewable @State var text = ""

    ChakTextField(
        label: "Label",
        text: $text,
        placeholder: "Placeholder",
        isRequired: true
    )
    .padding()
}

#Preview("오류") {
    @Previewable @State var text = ""

    ChakTextField(
        label: "Label",
        text: $text,
        placeholder: "Placeholder",
        isRequired: true,
        errorMessage: "Error Message"
    )
    .padding()
}

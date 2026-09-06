import SwiftUI

/// WorkBuddy-style quick skill and expert access strip elevated above the composer input.
/// Renders frequently used skills based on usage tracking, and reveals secondary
/// prompt chips when a skill is active.
struct YouziSimpleSkillBar: View {
    @Environment(YouziProductModel.self) private var productModel
    @Binding var draft: String
    @State private var selectedSkillID: UUID?

    private var availableSkills: [YouziSkill] {
        let ranked = productModel.rankedSkills(limit: 8)
        if !ranked.isEmpty { return ranked }
        return Array(productModel.document.skills.prefix(8))
    }

    private var selectedSkill: YouziSkill? {
        guard let selectedSkillID else { return nil }
        return availableSkills.first { $0.id == selectedSkillID }
            ?? productModel.document.skills.first { $0.id == selectedSkillID }
    }

    private var secondaryPrompts: [String] {
        guard let selectedSkill else { return [] }
        return YouziSkillPromptCatalog.prompts(forSkillNamed: selectedSkill.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: RapidTheme.Space.xs) {
            // Row 1: Frequently used skills
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: RapidTheme.Space.xs) {
                    ForEach(availableSkills) { skill in
                        let isSelected = skill.id == selectedSkillID
                        Button {
                            toggleSkill(skill)
                        } label: {
                            HStack(spacing: RapidTheme.Space.xxs) {
                                Image(systemName: isSelected ? "sparkles" : "bolt.circle")
                                    .font(.system(size: 11))
                                Text(skill.name)
                                    .font(RapidFont.caption)
                            }
                            .padding(.horizontal, RapidTheme.Space.sm)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(isSelected ? RapidTheme.brandPrimary.opacity(0.15) : RapidTheme.surfaceRaised)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(isSelected ? RapidTheme.brandPrimary : RapidTheme.hairlineStrong, lineWidth: 1)
                            )
                            .foregroundStyle(isSelected ? RapidTheme.brandPrimary : RapidTheme.textPrimary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("YouziSimple.SkillBar.Skill.\(skill.name)")
                    }
                }
                .padding(.horizontal, 2)
            }

            // Row 2: Secondary helper prompt chips (when a skill is chosen)
            if !secondaryPrompts.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: RapidTheme.Space.xs) {
                        ForEach(secondaryPrompts, id: \.self) { prompt in
                            Button {
                                appendPrompt(prompt)
                            } label: {
                                HStack(spacing: RapidTheme.Space.xxs) {
                                    Image(systemName: "plus.circle")
                                        .font(.system(size: 10))
                                    Text(prompt)
                                        .font(RapidFont.caption)
                                }
                                .padding(.horizontal, RapidTheme.Space.sm)
                                .padding(.vertical, 3)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(RapidTheme.surfaceSidebar)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .strokeBorder(RapidTheme.hairline, lineWidth: 1)
                                )
                                .foregroundStyle(RapidTheme.textSecondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("YouziSimple.SkillBar.Prompt.\(prompt)")
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("YouziSimple.SkillBar")
    }

    private func toggleSkill(_ skill: YouziSkill) {
        if selectedSkillID == skill.id {
            selectedSkillID = nil
        } else {
            selectedSkillID = skill.id
            productModel.markSkillUsed(skill.id)
        }
    }

    private func appendPrompt(_ prompt: String) {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            draft = prompt
        } else {
            draft = "\(trimmed)\n\(prompt)"
        }
    }
}

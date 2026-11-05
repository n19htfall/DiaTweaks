#import "TidyTabs.h"

// Which model tidies, picked on the Tidy Tabs page: Apple's on this Mac (Model.swift), or Claude through Claude Code
// (Claude.swift). A Claude choice is the model's name.
NSString *DPTidyAppleUnavailableReason(void);
NSString *DPTidyClaudeUnavailableReason(void);
void DPTidyAskApple(NSArray *tabs, void (^done)(NSArray *groups, NSString *error));
void DPTidyAskClaude(NSString *model, NSArray *tabs, void (^done)(NSArray *groups, NSString *error));

NSMenu *DPTidyModels(void) {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Group with"];
    [menu addItemWithTitle:@"Apple Intelligence" action:nil keyEquivalent:@""].representedObject = @"apple";
    [menu addItem:[NSMenuItem sectionHeaderWithTitle:@"Claude Code"]];
    NSArray<NSString *> *titles = @[ @"Claude Opus 5.5", @"Claude Sonnet 5.5", @"Claude Haiku 5.5" ];
    NSArray<NSString *> *models = @[ @"claude-opus-5-5", @"claude-sonnet-5-5", @"claude-haiku-5-5" ];
    for (NSUInteger i = 0; i < models.count; i++)
        [menu addItemWithTitle:titles[i] action:nil keyEquivalent:@""].representedObject = models[i];
    return menu;
}

static NSString *DPTidyClaudeModel(void) {
    NSString *choice = DPChoice(&DPTidyTabs);
    return [choice hasPrefix:@"claude-"] ? choice : nil;
}

NSString *DPTidyUnavailableReason(void) {
    return DPTidyClaudeModel() ? DPTidyClaudeUnavailableReason() : DPTidyAppleUnavailableReason();
}

void DPTidyAsk(NSArray *tabs, void (^done)(NSArray *groups, NSString *error)) {
    NSString *model = DPTidyClaudeModel();
    if (model) DPTidyAskClaude(model, tabs, done);
    else DPTidyAskApple(tabs, done);
}

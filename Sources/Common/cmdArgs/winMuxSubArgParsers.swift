// Flag helpers WinMux's own commands use, as they were before upstream removed them (S2). They print nothing, so they
// carry no wording. Value flags in WinMux commands use upstream's singleValueSubArgParser, windowIdSubArgParser and
// workspaceSubArgParser, so a flag's errors read the same in every command.

func optionalTrueBoolFlag<T>(_ keyPath: SendableWritableKeyPath<T, Bool?>) -> SubArgParser<T, Bool?> {
    ArgParser(keyPath, constSubArgParserFun(true))
}

func optionalFalseBoolFlag<T>(_ keyPath: SendableWritableKeyPath<T, Bool?>) -> SubArgParser<T, Bool?> {
    ArgParser(keyPath, constSubArgParserFun(false))
}

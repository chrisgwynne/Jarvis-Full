// LM Studio has been replaced by llama.cpp as the local provider.
// This typealias keeps legacy test helpers compiling during the transition.
@available(*, deprecated, renamed: "LlamaCppProvider")
typealias LMStudioProvider = LlamaCppProvider

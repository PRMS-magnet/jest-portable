--!strict

export type ModuleKind = "authored" | "native" | "preloaded"

export type ResolvedModule = {
	read Key: any,
	read Kind: ModuleKind,
	read Reference: any,
	read SourceLabel: string,
}

export type ModuleHost = {
	CanonicalizeEntry: (self: ModuleHost, Source: any) -> ResolvedModule,
	-- Path is below the tree's packages folder and has no extension, like jest_circus/src/JestCircus/circus/init
	CanonicalizeFramework: (self: ModuleHost, Path: string) -> ResolvedModule,
	Dispose: (self: ModuleHost) -> (),
	Execute: (self: ModuleHost, Module: ResolvedModule, Environment: { [any]: any }) -> { [number]: any, n: number },
	LoadNative: (self: ModuleHost, Module: ResolvedModule) -> any,
	Resolve: (self: ModuleHost, From: ResolvedModule, Request: string) -> ResolvedModule,
}

return {}

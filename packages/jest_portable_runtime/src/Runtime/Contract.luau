--!strict

export type TaskRoutine = ((...any) -> ...any) | thread

export type TaskCapabilities = {
	read Cancel: (Thread: thread) -> (),
	read Defer: (Routine: TaskRoutine, ...any) -> thread,
	read Delay: (Seconds: number, Routine: TaskRoutine, ...any) -> thread,
	read Spawn: (Routine: TaskRoutine, ...any) -> thread,
	read Wait: (Seconds: number?) -> number,
}

export type CapabilityRefusal = {
	read Capability: string,
	read Code: string,
	read Message: string,
}

export type RobloxCapabilities = {
	read GetService: (Name: string) -> unknown?,
	read IsInstance: (Value: unknown) -> boolean,
	read NewInstance: (ClassName: string) -> unknown?,
}

export type RobloxResolution = {
	read Capability: RobloxCapabilities?,
	read Refusal: CapabilityRefusal?,
	read Status: "available" | "unsupported",
}

-- Names the module host Jest's runtime loads spec modules with; the host modules live beside that runtime
export type ModuleHostName = "Lute" | "Roblox"

export type RuntimeCapabilities = {
	read JsonDecode: (Source: string) -> unknown,
	read JsonEncode: (Value: unknown) -> string,
	read ModuleHost: ModuleHostName?,
	read Roblox: RobloxCapabilities?,
	read Task: TaskCapabilities,
	read WriteOutput: (Message: string) -> (),
	read WriteWarning: (Message: string) -> (),
}

-- Builds a fresh capability set each call, so each spec runtime gets its own scheduler
export type RuntimeProvider = {
	read Create: (HostTask: unknown?) -> RuntimeCapabilities,
}

return {}

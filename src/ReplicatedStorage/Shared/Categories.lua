--!strict
--[[
	Categories  (ModuleScript)  ·  ReplicatedStorage/Shared/Categories

	Preset categories that free players choose from when they are the Caller.
	Each round the server offers a random handful (Config.Category.ChoicesOffered)
	so the list stays fresh and fits on a phone screen.

	Add, remove or reorder freely. The server only ever sends indexes, so keep
	this module identical on server and client (it is, because it lives in
	ReplicatedStorage).
]]

local Categories: { string } = {
	"Fruits",
	"Animals",
	"Countries",
	"Colors",
	"Sports",
	"Pizza Toppings",
	"Ice Cream Flavors",
	"Things in a Kitchen",
	"Superheroes",
	"Board Games",
	"Musical Instruments",
	"Car Brands",
	"Things at the Beach",
	"Dog Breeds",
	"Vegetables",
	"Breakfast Foods",
	"Things That Are Yellow",
	"Clothing",
	"School Subjects",
	"Jobs",
	"Weather",
	"Things in a Detective's Office",
	"Clues at a Crime Scene",
	"Cartoon Characters",
	"Sea Creatures",
	"Things With Wheels",
	"Space Stuff",
	"Desserts",
	"Bugs",
	"Birds",
	"Video Game Characters",
	"Halloween Costumes",
	"Things in a Backpack",
	"Candy",
	"Farm Animals",
	"Things That Fly",
}

return table.freeze(Categories)

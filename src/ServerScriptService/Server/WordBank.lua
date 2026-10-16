--!strict
--[[
	WordBank  (ModuleScript)  ·  ServerScriptService/Server/WordBank

	What the AI detectives know. Every case file (category) has:
	    name      the text a bot Caller puts on the TV ("Types of cars")
	    keywords  words that identify the topic in ANY category text
	    answers   at least 25 answers a bot may give / accept

	    WordBank.lookup(categoryText)   best-matching Category, or nil
	    WordBank.random(rng)            a random Category (bot Callers)
	    WordBank.knows(category, text)  is `text` (by AnswerRules.key) one of its answers?
	    WordBank.Generic                plain nouns for unknown / off-topic answers

	MATCHING (lookup)
	  The category text is lower-cased, apostrophes dropped, other
	  punctuation turned into spaces, and every word is also tried in a
	  singular form (plural stripping: "cities" -> "city", "dishes" -> "dish",
	  "villains" -> "villain"). Only the CATEGORY text is stripped; answers are
	  compared exactly by AnswerRules.key (no plural merging, same as humans).
	  A keyword scores 1, a multi-word keyword phrase scores 2; the highest
	  score wins, ties go to the earlier category. No keyword: nil.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AnswerRules = require(ReplicatedStorage.Shared.AnswerRules)

export type Category = {
	name: string,
	keywords: { string },
	answers: { string },
}

local WordBank = {}

local CATEGORIES: { Category } = {
	{
		name = "Things found in a detective's office",
		keywords = { "detective office", "office", "desk", "agency", "precinct" },
		answers = {
			"Typewriter", "Fedora", "Trench coat", "Magnifying glass", "Filing cabinet", "Desk lamp", "Ashtray",
			"Revolver", "Notepad", "Telephone", "Case file", "Photograph", "Whiskey bottle", "Coffee mug",
			"Venetian blinds", "Calendar", "Rolodex", "Handcuffs", "Fingerprint kit", "Pocket watch", "Ceiling fan",
			"Wanted poster", "Map", "Newspaper", "Fountain pen", "Hat rack", "Safe", "Radio", "Envelope", "Badge",
			"Flashlight", "Briefcase",
		},
	},
	{
		name = "Types of cars",
		keywords = { "car", "automobile", "vehicle", "sedan", "carmaker", "motor" },
		answers = {
			"Sedan", "Coupe", "Convertible", "Hatchback", "Station wagon", "Pickup truck", "Minivan", "SUV",
			"Limousine", "Roadster", "Sports car", "Muscle car", "Taxi", "Jeep", "Hot rod", "Police cruiser", "Hearse",
			"Electric car", "Hybrid", "Race car", "Ford", "Toyota", "Ferrari", "Cadillac", "Porsche", "Volkswagen",
			"Tesla", "Honda", "Chevrolet", "BMW",
		},
	},
	{
		name = "Animals with four legs",
		keywords = { "four leg", "four legged", "fourlegged", "quadruped", "leg" },
		answers = {
			"Dog", "Cat", "Horse", "Cow", "Pig", "Sheep", "Goat", "Lion", "Tiger", "Elephant", "Giraffe", "Zebra",
			"Bear", "Wolf", "Fox", "Rabbit", "Mouse", "Rat", "Deer", "Camel", "Rhino", "Hippo", "Cheetah", "Leopard",
			"Donkey", "Squirrel", "Raccoon", "Hamster", "Moose", "Panda", "Crocodile", "Turtle", "Lizard", "Frog",
		},
	},
	{
		name = "Famous movie villains",
		keywords = { "villain", "movie villain", "bad guy", "antagonist", "evil" },
		answers = {
			"Darth Vader", "The Joker", "Hannibal Lecter", "Voldemort", "Thanos", "Norman Bates", "Freddy Krueger",
			"Jason Voorhees", "Michael Myers", "Pennywise", "Scar", "Ursula", "Jafar", "Maleficent", "Cruella de Vil",
			"Captain Hook", "Hans Gruber", "Agent Smith", "Loki", "Magneto", "Bane", "Gollum", "Sauron", "Dracula",
			"Goldfinger", "Blofeld", "Khan", "The Terminator", "Annie Wilkes", "Nurse Ratched", "Anton Chigurh",
		},
	},
	{
		name = "Things that are cold",
		keywords = { "cold", "freezing", "frozen", "icy", "chilly", "chill" },
		answers = {
			"Ice", "Snow", "Ice cream", "Freezer", "Fridge", "Glacier", "Iceberg", "Popsicle", "Snowman", "Icicle",
			"Penguin", "Antarctica", "Arctic", "Frost", "Hail", "Sleet", "Ice cube", "Winter", "North Pole", "Igloo",
			"Blizzard", "Slushie", "Frozen peas", "Polar bear", "Ice rink", "Snowflake", "Morgue", "Iced tea",
			"Cold case",
		},
	},
	{
		name = "Breakfast foods",
		keywords = { "breakfast", "brunch", "morning" },
		answers = {
			"Pancakes", "Waffles", "Eggs", "Bacon", "Sausage", "Toast", "Cereal", "Oatmeal", "Bagel", "Muffin",
			"Croissant", "French toast", "Hash browns", "Omelette", "Yogurt", "Granola", "Grits", "Porridge",
			"Biscuits", "Donut", "Scrambled eggs", "Fried eggs", "Smoothie", "Orange juice", "Coffee", "Crepes",
			"Breakfast burrito", "Fruit salad", "Danish", "Ham",
		},
	},
	{
		name = "Fruits",
		keywords = { "fruit", "berry" },
		answers = {
			"Apple", "Banana", "Cherry", "Orange", "Grape", "Pear", "Peach", "Plum", "Mango", "Pineapple",
			"Strawberry", "Blueberry", "Raspberry", "Watermelon", "Kiwi", "Lemon", "Lime", "Papaya", "Apricot",
			"Coconut", "Fig", "Pomegranate", "Grapefruit", "Cantaloupe", "Blackberry", "Durian", "Lychee", "Guava",
			"Passion fruit", "Nectarine", "Tangerine", "Cranberry", "Avocado",
		},
	},
	{
		name = "Vegetables",
		keywords = { "vegetable", "veggie", "veg" },
		answers = {
			"Carrot", "Potato", "Broccoli", "Spinach", "Lettuce", "Cabbage", "Onion", "Garlic", "Pepper", "Cucumber",
			"Celery", "Corn", "Peas", "Green beans", "Cauliflower", "Zucchini", "Eggplant", "Kale", "Radish", "Beet",
			"Turnip", "Asparagus", "Pumpkin", "Squash", "Leek", "Artichoke", "Sweet potato", "Brussels sprouts",
			"Mushroom", "Tomato",
		},
	},
	{
		name = "Animals",
		keywords = { "animal", "creature", "wildlife", "beast", "mammal", "pet", "zoo" },
		answers = {
			"Dog", "Cat", "Elephant", "Lion", "Tiger", "Bear", "Wolf", "Fox", "Rabbit", "Horse", "Monkey", "Gorilla",
			"Kangaroo", "Koala", "Penguin", "Owl", "Eagle", "Shark", "Whale", "Dolphin", "Snake", "Lizard", "Frog",
			"Turtle", "Crocodile", "Giraffe", "Zebra", "Hippo", "Rhino", "Camel", "Deer", "Moose", "Bat", "Squirrel",
			"Raccoon", "Skunk", "Otter", "Beaver",
		},
	},
	{
		name = "Birds",
		keywords = { "bird", "fowl", "feathered", "feather" },
		answers = {
			"Eagle", "Hawk", "Falcon", "Owl", "Crow", "Raven", "Sparrow", "Robin", "Pigeon", "Dove", "Parrot",
			"Penguin", "Flamingo", "Swan", "Duck", "Goose", "Chicken", "Turkey", "Ostrich", "Emu", "Peacock",
			"Pelican", "Seagull", "Hummingbird", "Woodpecker", "Cardinal", "Blue jay", "Vulture", "Stork", "Heron",
			"Kingfisher", "Toucan", "Canary", "Magpie",
		},
	},
	{
		name = "Sea creatures",
		keywords = { "sea", "ocean", "marine", "fish", "underwater", "aquatic", "sea creature" },
		answers = {
			"Shark", "Whale", "Dolphin", "Octopus", "Squid", "Jellyfish", "Starfish", "Crab", "Lobster", "Shrimp",
			"Seahorse", "Eel", "Stingray", "Clam", "Oyster", "Seal", "Walrus", "Sea turtle", "Tuna", "Salmon", "Cod",
			"Swordfish", "Clownfish", "Pufferfish", "Barracuda", "Anchovy", "Sardine", "Manatee", "Orca",
			"Sea urchin", "Mackerel",
		},
	},
	{
		name = "Countries",
		keywords = { "country", "nation", "nationality" },
		answers = {
			"France", "Germany", "Italy", "Spain", "Japan", "China", "India", "Brazil", "Canada", "Mexico", "Egypt",
			"Kenya", "Nigeria", "Australia", "Russia", "Peru", "Chile", "Argentina", "Sweden", "Norway", "Finland",
			"Greece", "Turkey", "Ireland", "Portugal", "Poland", "Vietnam", "Thailand", "Morocco", "Iceland", "Cuba",
			"Jamaica",
		},
	},
	{
		name = "Cities",
		keywords = { "city", "town", "capital", "metropolis" },
		answers = {
			"Paris", "London", "Tokyo", "New York", "Chicago", "Los Angeles", "Rome", "Berlin", "Madrid", "Moscow",
			"Cairo", "Sydney", "Toronto", "Mumbai", "Beijing", "Seoul", "Istanbul", "Dubai", "Lisbon", "Vienna",
			"Prague", "Amsterdam", "Dublin", "Boston", "Miami", "Seattle", "San Francisco", "Rio de Janeiro",
			"Buenos Aires", "Mexico City", "Bangkok", "Athens",
		},
	},
	{
		name = "Colors",
		keywords = { "color", "colour", "shade", "hue" },
		answers = {
			"Red", "Blue", "Green", "Yellow", "Orange", "Purple", "Pink", "Brown", "Black", "White", "Gray", "Grey",
			"Violet", "Indigo", "Turquoise", "Teal", "Maroon", "Navy", "Beige", "Gold", "Silver", "Crimson",
			"Scarlet", "Magenta", "Cyan", "Lavender", "Olive", "Tan", "Ivory", "Coral", "Amber", "Charcoal",
		},
	},
	{
		name = "Sports",
		keywords = { "sport", "athletic", "olympic", "ball game" },
		answers = {
			"Soccer", "Football", "Basketball", "Baseball", "Tennis", "Golf", "Hockey", "Cricket", "Rugby",
			"Volleyball", "Boxing", "Wrestling", "Swimming", "Cycling", "Skiing", "Snowboarding", "Surfing",
			"Skateboarding", "Badminton", "Table tennis", "Bowling", "Archery", "Fencing", "Rowing", "Karate", "Judo",
			"Lacrosse", "Polo", "Handball", "Gymnastics", "Marathon", "Curling",
		},
	},
	{
		name = "Musical instruments",
		keywords = { "instrument", "musical", "music", "band", "orchestra" },
		answers = {
			"Piano", "Guitar", "Violin", "Cello", "Drums", "Trumpet", "Saxophone", "Flute", "Clarinet", "Trombone",
			"Tuba", "Harp", "Banjo", "Ukulele", "Harmonica", "Accordion", "Bass", "Oboe", "Bagpipes", "Xylophone",
			"Tambourine", "Organ", "Synthesizer", "French horn", "Mandolin", "Bassoon", "Triangle", "Cymbals", "Viola",
			"Bongos", "Sitar", "Kazoo",
		},
	},
	{
		name = "Jobs",
		keywords = { "job", "occupation", "profession", "career", "worker", "employment" },
		answers = {
			"Detective", "Doctor", "Nurse", "Teacher", "Lawyer", "Judge", "Police officer", "Firefighter", "Chef",
			"Baker", "Pilot", "Farmer", "Plumber", "Electrician", "Carpenter", "Mechanic", "Dentist", "Architect",
			"Engineer", "Accountant", "Journalist", "Photographer", "Waiter", "Bartender", "Librarian",
			"Mail carrier", "Taxi driver", "Butcher", "Tailor", "Barber", "Scientist", "Soldier", "Actor", "Musician",
		},
	},
	{
		name = "Things in a kitchen",
		keywords = { "kitchen", "cooking", "cook", "utensil", "cookware" },
		answers = {
			"Stove", "Oven", "Fridge", "Microwave", "Toaster", "Sink", "Kettle", "Blender", "Frying pan", "Saucepan",
			"Spatula", "Whisk", "Ladle", "Cutting board", "Knife", "Fork", "Spoon", "Plate", "Bowl", "Cup",
			"Colander", "Grater", "Rolling pin", "Oven mitt", "Dishwasher", "Apron", "Tongs", "Peeler", "Can opener",
			"Coffee maker", "Teapot", "Measuring cup",
		},
	},
	{
		name = "Murder weapons in a mystery",
		keywords = { "weapon", "murder", "crime", "mystery", "killer", "whodunit" },
		answers = {
			"Candlestick", "Revolver", "Rope", "Lead pipe", "Wrench", "Dagger", "Knife", "Poison", "Arsenic",
			"Hammer", "Axe", "Crowbar", "Baseball bat", "Ice pick", "Letter opener", "Shotgun", "Pistol", "Rifle",
			"Sword", "Brick", "Frying pan", "Golf club", "Fireplace poker", "Scissors", "Cyanide", "Spear", "Trophy",
			"Statue", "Hatpin", "Umbrella",
		},
	},
	{
		name = "Body parts",
		keywords = { "body part", "body", "anatomy", "limb" },
		answers = {
			"Head", "Arm", "Leg", "Hand", "Foot", "Finger", "Toe", "Elbow", "Knee", "Shoulder", "Neck", "Nose", "Ear",
			"Eye", "Mouth", "Lip", "Tooth", "Tongue", "Chin", "Cheek", "Forehead", "Wrist", "Ankle", "Hip", "Heart",
			"Lung", "Liver", "Stomach", "Brain", "Spine", "Thumb", "Eyebrow",
		},
	},
	{
		name = "Clothing",
		keywords = { "clothing", "clothe", "clothes", "outfit", "garment", "wear", "fashion", "wardrobe" },
		answers = {
			"Shirt", "Pants", "Jeans", "Dress", "Skirt", "Jacket", "Coat", "Trench coat", "Sweater", "Hoodie",
			"Scarf", "Gloves", "Hat", "Fedora", "Socks", "Shoes", "Boots", "Sneakers", "Tie", "Bow tie", "Vest", "Suit",
			"Blazer", "Shorts", "Pajamas", "Belt", "Raincoat", "Overalls", "Cardigan", "Tuxedo", "Beanie", "Sandals",
		},
	},
	{
		name = "Desserts",
		keywords = { "dessert", "sweet", "candy", "cake", "pastry", "treat" },
		answers = {
			"Cake", "Pie", "Ice cream", "Brownie", "Cookie", "Cupcake", "Cheesecake", "Pudding", "Tiramisu", "Donut",
			"Eclair", "Macaron", "Sundae", "Gelato", "Sorbet", "Fudge", "Truffle", "Creme brulee", "Apple pie",
			"Cannoli", "Baklava", "Churros", "Flan", "Mousse", "Trifle", "Lollipop", "Chocolate", "Marshmallow",
			"Toffee", "Caramel",
		},
	},
	{
		name = "Drinks",
		keywords = { "drink", "beverage", "cocktail", "juice", "soda" },
		answers = {
			"Water", "Coffee", "Tea", "Milk", "Orange juice", "Apple juice", "Lemonade", "Soda", "Cola", "Root beer",
			"Hot chocolate", "Milkshake", "Smoothie", "Iced tea", "Espresso", "Latte", "Cappuccino", "Whiskey", "Wine",
			"Martini", "Champagne", "Cider", "Ginger ale", "Kombucha", "Eggnog", "Punch", "Sparkling water",
			"Energy drink", "Bourbon", "Gin", "Rum",
		},
	},
	{
		name = "Things that are red",
		keywords = { "red", "crimson", "scarlet" },
		answers = {
			"Apple", "Strawberry", "Cherry", "Tomato", "Fire truck", "Stop sign", "Rose", "Blood", "Ruby", "Lipstick",
			"Ketchup", "Lobster", "Ladybug", "Mars", "Brick", "Cardinal", "Stop light", "Valentine", "Chili pepper",
			"Raspberry", "Watermelon", "Radish", "Fire hydrant", "Santa suit", "Red carpet", "Poppy", "Cranberry",
			"Beet", "Clown nose", "Lava", "Paprika",
		},
	},
	{
		name = "Things with wheels",
		keywords = { "wheel", "wheeled" },
		answers = {
			"Car", "Bicycle", "Bus", "Truck", "Train", "Motorcycle", "Skateboard", "Scooter", "Wheelchair",
			"Shopping cart", "Stroller", "Wagon", "Wheelbarrow", "Tractor", "Roller skates", "Tricycle", "Unicycle",
			"Go kart", "Suitcase", "Office chair", "Lawn mower", "Forklift", "Ambulance", "Taxi", "Tram", "Airplane",
			"Cannon", "Chariot", "Carriage", "Rickshaw", "Bulldozer", "Fire truck",
		},
	},
	{
		name = "Tools",
		keywords = { "tool", "hardware", "toolbox", "workshop" },
		answers = {
			"Hammer", "Screwdriver", "Wrench", "Pliers", "Saw", "Drill", "Chisel", "Level", "Tape measure", "Crowbar",
			"Sledgehammer", "Axe", "Shovel", "Rake", "Hoe", "Trowel", "Sandpaper", "File", "Clamp", "Vise", "Hacksaw",
			"Mallet", "Pickaxe", "Utility knife", "Socket wrench", "Soldering iron", "Staple gun", "Nail gun",
			"Allen key", "Flashlight", "Ladder", "Wire cutters",
		},
	},
	{
		name = "Weather",
		keywords = { "weather", "forecast", "storm", "climate" },
		answers = {
			"Rain", "Snow", "Sleet", "Hail", "Fog", "Mist", "Drizzle", "Thunder", "Lightning", "Wind", "Tornado",
			"Hurricane", "Blizzard", "Sunshine", "Cloudy", "Heatwave", "Frost", "Dew", "Monsoon", "Typhoon", "Breeze",
			"Gale", "Rainbow", "Smog", "Drought", "Flood", "Sandstorm", "Humidity", "Overcast", "Downpour",
			"Thunderstorm", "Cyclone",
		},
	},
	{
		name = "Board games",
		keywords = { "board game", "game", "boardgame", "tabletop" },
		answers = {
			"Chess", "Checkers", "Monopoly", "Scrabble", "Clue", "Risk", "Backgammon", "Go", "Battleship",
			"Connect Four", "Mouse Trap", "Sorry", "Trouble", "Candy Land", "Pictionary", "Trivial Pursuit", "Catan",
			"Ticket to Ride", "Mahjong", "Dominoes", "Othello", "Stratego", "Operation", "Guess Who", "Yahtzee",
			"Parcheesi", "Mancala", "Jenga", "Boggle", "Cranium", "Twister",
		},
	},
	{
		name = "Things in outer space",
		keywords = { "space", "outer space", "planet", "astronomy", "star", "galaxy", "solar", "universe", "cosmos" },
		answers = {
			"Mercury", "Venus", "Earth", "Mars", "Jupiter", "Saturn", "Uranus", "Neptune", "Pluto", "Moon", "Sun",
			"Comet", "Asteroid", "Meteor", "Galaxy", "Nebula", "Black hole", "Supernova", "Milky Way", "Astronaut",
			"Rocket", "Satellite", "Space station", "Telescope", "Orbit", "Crater", "Quasar", "Constellation",
			"Big Dipper", "Andromeda", "Eclipse", "Shooting star",
		},
	},
	{
		name = "Things at the beach",
		keywords = { "beach", "seaside", "shore", "coast", "summer" },
		answers = {
			"Sand", "Seashell", "Sandcastle", "Bucket", "Spade", "Towel", "Umbrella", "Sunscreen", "Sunglasses",
			"Swimsuit", "Flip flops", "Surfboard", "Lifeguard", "Wave", "Seagull", "Crab", "Beach ball", "Cooler",
			"Kite", "Pier", "Boardwalk", "Lighthouse", "Driftwood", "Seaweed", "Starfish", "Boat", "Sunhat",
			"Volleyball", "Ice cream", "Palm tree", "Tide pool", "Snorkel",
		},
	},
	{
		name = "Things in a dark alley",
		keywords = { "alley", "dark alley", "noir", "street", "shadow", "dark", "underworld", "night" },
		answers = {
			"Trash can", "Dumpster", "Rat", "Stray cat", "Puddle", "Fire escape", "Graffiti", "Streetlamp",
			"Neon sign", "Crate", "Broken bottle", "Newspaper", "Cigarette butt", "Manhole", "Back door", "Fog",
			"Shadow", "Footprints", "Brick wall", "Drainpipe", "Pigeon", "Cardboard box", "Trench coat",
			"Getaway car", "Informant", "Rain", "Ladder", "Chain link fence", "Matchbook", "Steam vent", "Lost glove",
		},
	},
	{
		name = "School subjects",
		keywords = { "school", "subject", "class", "classroom", "lesson", "course" },
		answers = {
			"Math", "English", "History", "Science", "Biology", "Chemistry", "Physics", "Geography", "Art", "Music",
			"Drama", "Spanish", "French", "German", "Latin", "Economics", "Psychology", "Philosophy",
			"Computer science", "Algebra", "Geometry", "Calculus", "Literature", "Physical education", "Sociology",
			"Astronomy", "Statistics", "Health", "Woodshop", "Civics", "Debate", "Home economics",
		},
	},
	{
		name = "Furniture",
		keywords = { "furniture", "house", "home", "living room", "bedroom", "household" },
		answers = {
			"Chair", "Table", "Sofa", "Couch", "Bed", "Desk", "Dresser", "Wardrobe", "Bookshelf", "Armchair", "Stool",
			"Bench", "Ottoman", "Nightstand", "Cabinet", "Recliner", "Futon", "Bunk bed", "Rocking chair",
			"Coffee table", "Sideboard", "Hammock", "Crib", "Mirror", "Lamp", "Rug", "Filing cabinet", "Coat rack",
			"Chest", "Vanity", "Footstool", "Hutch",
		},
	},
	{
		name = "Flowers",
		keywords = { "flower", "plant", "garden", "bloom", "bouquet" },
		answers = {
			"Rose", "Tulip", "Daisy", "Lily", "Sunflower", "Orchid", "Daffodil", "Carnation", "Lavender", "Violet",
			"Poppy", "Iris", "Marigold", "Peony", "Hydrangea", "Lotus", "Jasmine", "Magnolia", "Chrysanthemum",
			"Dandelion", "Begonia", "Petunia", "Gardenia", "Hibiscus", "Lilac", "Camellia", "Azalea", "Zinnia",
			"Snapdragon", "Bluebell", "Forget me not", "Buttercup",
		},
	},
	{
		name = "Pizza toppings",
		keywords = { "pizza", "topping" },
		answers = {
			"Pepperoni", "Mushrooms", "Onions", "Sausage", "Bacon", "Extra cheese", "Black olives", "Green peppers",
			"Pineapple", "Spinach", "Ham", "Anchovies", "Jalapenos", "Tomatoes", "Basil", "Garlic", "Chicken", "Beef",
			"Artichoke", "Feta", "Mozzarella", "Salami", "Meatballs", "Broccoli", "Corn", "Arugula", "Prosciutto",
			"Ricotta", "Red onion", "Chili flakes", "Eggplant", "Shrimp",
		},
	},
	{
		name = "Famous detectives",
		keywords = { "detective", "sleuth", "investigator", "private eye", "gumshoe", "inspector" },
		answers = {
			"Sherlock Holmes", "Hercule Poirot", "Miss Marple", "Sam Spade", "Philip Marlowe", "Columbo", "Dick Tracy",
			"Nancy Drew", "Inspector Gadget", "Inspector Morse", "Batman", "Scooby Doo", "Encyclopedia Brown",
			"Jessica Fletcher", "Kojak", "Magnum", "Mike Hammer", "Nero Wolfe", "Ellery Queen", "Father Brown",
			"Inspector Clouseau", "Dirk Gently", "Veronica Mars", "Adrian Monk", "Lord Peter Wimsey", "Jules Maigret",
			"Charlie Chan", "Rockford", "Hardy Boys", "Shaft", "Jack Reacher",
		},
	},
	{
		name = "Insects",
		keywords = { "insect", "bug", "creepy crawly" },
		answers = {
			"Ant", "Bee", "Wasp", "Fly", "Mosquito", "Butterfly", "Moth", "Beetle", "Ladybug", "Grasshopper",
			"Cricket", "Dragonfly", "Firefly", "Termite", "Cockroach", "Flea", "Louse", "Hornet", "Cicada",
			"Praying mantis", "Caterpillar", "Stick insect", "Earwig", "Weevil", "Gnat", "Aphid", "Bumblebee",
			"Locust", "Silverfish", "Horsefly", "Damselfly", "Scarab",
		},
	},
	{
		name = "Things that fly",
		keywords = { "fly", "flying", "sky", "airborne", "wing", "winged" },
		answers = {
			"Airplane", "Helicopter", "Bird", "Kite", "Balloon", "Rocket", "Drone", "Bat", "Butterfly", "Bee", "Eagle",
			"Blimp", "Glider", "Jet", "Frisbee", "Paper airplane", "Hot air balloon", "Dragon", "Superman", "Owl",
			"Mosquito", "Parachute", "Fly", "Seagull", "Hang glider", "Spaceship", "Bumblebee", "Boomerang",
			"Dragonfly", "Pigeon", "Crow", "Flying squirrel",
		},
	},
	{
		name = "Jewels and stolen valuables",
		keywords = { "jewel", "jewelry", "jewellery", "valuable", "treasure", "heist", "loot", "gem", "stolen" },
		answers = {
			"Diamond", "Ruby", "Emerald", "Sapphire", "Pearl necklace", "Gold watch", "Silver ring", "Bracelet",
			"Brooch", "Earrings", "Tiara", "Crown", "Locket", "Cufflinks", "Pendant", "Gold bar", "Opal", "Amethyst",
			"Topaz", "Jade", "Rare stamp", "Painting", "Bearer bonds", "Cash", "Coin collection", "Antique vase",
			"Pocket watch", "Signet ring", "Ming vase", "Faberge egg", "Maltese Falcon",
		},
	},
	{
		name = "Emotions",
		keywords = { "emotion", "feeling", "mood" },
		answers = {
			"Happy", "Sad", "Angry", "Afraid", "Jealous", "Nervous", "Excited", "Bored", "Lonely", "Proud", "Ashamed",
			"Guilty", "Anxious", "Calm", "Confused", "Curious", "Surprised", "Disgusted", "Hopeful", "Grateful",
			"Embarrassed", "Frustrated", "Content", "Nostalgic", "Suspicious", "Paranoid", "Relieved", "Furious",
			"Joyful", "Gloomy", "Envious", "Restless",
		},
	},
}

-- Plain nouns: a bot that doesn't know the topic (or slips up) says one of these.
WordBank.Generic = {
	"Umbrella", "Teapot", "Pillow", "Lamp", "Button", "Candle", "Bucket", "Mirror", "Blanket", "Basket", "Feather",
	"Pebble", "Clock", "Spoon", "Kettle", "Door", "Window", "Bottle", "Paper", "Pencil", "Envelope", "Coin", "Key",
	"Brush", "Comb", "Towel", "Sock", "Glove", "Box", "Bell", "Chain", "Hook", "Nail", "Wire", "Stamp", "Ribbon",
	"Sponge", "Soap", "Cork", "Tile", "Plank", "Barrel", "Jar", "Lid", "Book", "Rug", "Vase", "Whistle", "Marble",
	"Thimble", "Doorknob", "Matchbox", "Shoelace", "Paperclip", "Doormat", "Lampshade", "Keychain", "Teaspoon",
} :: { string }

WordBank.Categories = CATEGORIES

-- Repeat keys of every category's answers, for knows().
local answerKeys: { [Category]: { [string]: boolean } } = {}
for _, category in CATEGORIES do
	local keys: { [string]: boolean } = {}
	for _, answer in category.answers do
		keys[AnswerRules.key(answer)] = true
	end
	answerKeys[category] = keys
end

-- "detectives" -> "detective", "cities" -> "city", "dishes" -> "dish", "class" stays.
local function singular(word: string): string
	local length = #word
	if length > 4 and string.sub(word, -3) == "ies" then
		return string.sub(word, 1, -4) .. "y"
	end
	if length > 3 and string.sub(word, -2) == "es" then
		local stem = string.sub(word, 1, -3)
		local last = string.sub(stem, -1)
		local lastTwo = string.sub(stem, -2)
		if last == "s" or last == "x" or last == "z" or lastTwo == "ch" or lastTwo == "sh" then
			return stem
		end
	end
	if length > 3 and string.sub(word, -1) == "s" and string.sub(word, -2) ~= "ss" then
		return string.sub(word, 1, -2)
	end
	return word
end

-- " w1 w2 … " with every word singular, and the set of every word form.
local function normalize(text: string): (string, { [string]: boolean })
	local lowered = string.lower(text)
	lowered = string.gsub(lowered, "'", "")
	lowered = string.gsub(lowered, "\u{2019}", "") -- typographic apostrophe
	lowered = string.gsub(lowered, "[%p%c]", " ")
	local forms: { [string]: boolean } = {}
	local words: { string } = {}
	for word in string.gmatch(lowered, "%S+") do
		local one = singular(word)
		forms[word] = true
		forms[one] = true
		table.insert(words, one)
	end
	return " " .. table.concat(words, " ") .. " ", forms
end

local function score(category: Category, phrase: string, forms: { [string]: boolean }): number
	local total = 0
	for _, keyword in category.keywords do
		if string.find(keyword, " ", 1, true) then
			if string.find(phrase, " " .. keyword .. " ", 1, true) then
				total += 2
			end
		elseif forms[keyword] then
			total += 1
		end
	end
	return total
end

-- The category whose keywords best match `categoryText`, or nil if none does.
function WordBank.lookup(categoryText: string): Category?
	local phrase, forms = normalize(categoryText)
	local best: Category? = nil
	local bestScore = 0
	for _, category in CATEGORIES do
		local points = score(category, phrase, forms)
		if points > bestScore then
			best, bestScore = category, points
		end
	end
	return best
end

function WordBank.random(rng: Random): Category
	return CATEGORIES[rng:NextInteger(1, #CATEGORIES)]
end

-- Is `answer` (compared by AnswerRules.key) one of `category`'s answers?
function WordBank.knows(category: Category, answer: string): boolean
	local keys = answerKeys[category]
	return keys ~= nil and keys[AnswerRules.key(answer)] == true
end

return WordBank

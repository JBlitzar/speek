# speek


A modular speaker system. Right now, it has a couple of boards:

- Speek Amp: This is the flagship amplifier. It's a hybrid 2.1 design using the TPA3116D2 chip. It's built to handle 4Ω speakers. It outputs lines for a mono subwoofer, two stereo woofers, and two stereo tweeters.
- Speek RX: This is a Bluetooth audio reciever. It runs off of a qfn esp32 D0WD v3 and has a built-in headphone amp, or a normal line out for chaining.
- Speek PSU: This is a supporting PSU board. It has a USB-C PD trigger (for quick tests) and a barrel jack port for proper power (needed to power real flagship drivers). It can be used as a stable power source for pretty much anything. Note that the barrel jack supplies 24V while PD gives 20V. 

On modularity:

- Each board is self-contained and can be used on it's own. However, they can also all be used together. 


## \[Please Read\] Where do I find everything? AKA checklist

Why the monorepo?

TLDR because Madhav reccomended it. Most projects are one-off boards. This is a multi-board system. All of the proper documentation exists though.

- A good README
- Source files for your project
    - This includes hardware design, firmware, 3D assemblies, etc
- Production files (if applicable)
    - e
- JOURNAL.md if journalling on Git
- BOM.csv complete with functioning links (where applicable)
- A short description of what your project is
- A couple sentences on why you made the project
- PICTURES OF YOUR PROJECT
- A screenshot of a full 3D model with your project
- A screenshot of your PCB, if you have one
- A screenshot of your schematic, if you have one
- A wiring diagram, if you're doing any wiring that isn't on a PCB
- A BOM in table format at the end of the README


## What is this project?


## How to use?


## Gallery


## Schematics


## PCBs


## Production files


## BOM

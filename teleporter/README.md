### About
This teleporter script allows the creation of a teleporter network with up to 4096 independent teleporters (more if you use private channels). 
All communication between teleporters is done via color-coded enderchests from EnderStorage. This means
The teleporters don't require any other form of network connection, which makes it easy to build teleporters in remote locations or other dimensions.

### Features


### Required Mods
- OpenComputers
- EnderStorage
- Applied Energistics 2


### Installation
>[!IMPORTANT]
> The installation proces requires an internet card. (And therefore also an internet connection)
0. **Install OPPM.**  
To do this, craft the "OPPM (Package Manager)" floppy disk, insert it into your computer (or a disk drive connected to your computer) and run `install`
1. **Register this repository with OPPM.**  
Run `oppm register zappic3/opencomputersprojects`.
2. **Install the teleporter.**  
Run `oppm install teleporter`
3. **Run the program**  
The 'teleporter.lua' file should now be in your /usr directory. Navigate to it using `cd /usr` and run it with `teleporter`.
4. **Build the teleporter**  
If you haven't built a valid teleporter, the program will abort with a (hopefully helpful) error message.
If you don't want to build your own design, you can follow the build guide below.


### Example Teleporter Build Guide
> [!NOTE]
> This build was designed and tested for the GregTech: New Horizons modpack. 

Additional mods used in this build:
- **ProjectRed Transmission**  
(can be replaced with a different mod that adds redstone cables, mainly used to make the build smaller)
- **WR-CBR Logic**  
(can be replaced with a different wireless redstone mod and is not needed if you don't require wireless teleporter restarting)


<details>
  <summary><strong>Blocks Required</strong></summary>

**Other Blocks / Items:**
| Count | Item |
|-------|------|
| 1x | Computer Case (Tier 3) |
| 1x | EEPROM (Lua Bios) |
| 1x | Graphics Card<br>(Tier 2 works, but Tier 3 is recommended.) |
| 1x | Redstone Card (Tier 1) |
| 1x | Internet Card |
| 1x | Central Processing Unit (CPU) (Tier 1) |
| 1x | Hard Disk Drive (Tier 1) |
| 2x | Memory (Tier 2)<br>(Could possibly be downgraded, but I haven't tested that.) |
| 1x | OpenOS (Operating System) floppy disk<br>(If you want to install the teleporter software after the build) |
| 1x | OPPM (Package Manager) floppy disk<br>(If you want to install the teleporter software after the build) |
| 10x | Spatial Pylon<br>(If you change the design slightly, only 8 pylons are needed; the other two are purely cosmetic.) |
| 4x | ME Dense Covered Cable - Purple |
| 1x | ME Glass Cable - Fluix |
| 1x | Energy Cell or Dense Energy Cell |
| 1x | Spatial IO Port |
| 4x | Screen<br>(Tier 2 works, but Tier 3 is recommended.) |
| 1x | Purple Dye<br>(purely cosmetic) |
| 1x | Transposer |
| 1x | Adapter |
| 1x | Keyboard |
| 1x | Cable<br>(from OpenComputers) |
| 1x | Ender Chest<br>(from EnderStorage) |
| 6x | Framed Insulated Cable |
| 2x | Red Alloy Wire<br>(from ProjectRed Transmission) |
| 1x | Barrel<br>(from Et Futurum Requiem) or a different container with at least two slots |
| 1x | 2³ Spatial Storage Cell |
| 1x | Paper<br>(This is used as a "token", so it can be changed to any item you want.) |

**Power**  
You can use any power source you like. In this guide I will be using a combustion generator.
If you want to follow along exactly, you will additionally need:
| Count | Item |
|-------|------|
| 1x | Turbo Combustion Generator |
| 1x | Ender Tank<br>(from EnderStorage) |
| 1x | HV Tier (or higher) Cable |
| 1x | Energy Acceptor<br>(Applied Energistics 2) |

**Remote Restart**
This is not required for the base teleporter functionality. If you want to be able to remotely restart your teleporters (e.g., in case of a power outage), you will need:
| Count | Item |
|-------|------|
| 1x | Wireless Receiver<br>(From WR-CBE Logic)<br>(Or a different wireless redstone receiver) |
| 1x | Red Alloy Wire<br>(From ProjectRed Transmission or a different redstone cable)|
| 1x | Any Cover from Forge Microblocks<br>(If you don't have ForgeMicroblocks installed, you can just use<br>a bit more cable for a slightly  larger build instead of a cover)|

</details>

**Build guide coming soon**

### Usage
> [!CAUTION]
> Before using the teleporter, make sure that both the receiver and transmitter are chunkloaded. Failing to chunkload the transmitter will get you stuck in the spatial storage cell dimension.

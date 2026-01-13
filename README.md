# PaperMC Docker
This is forked Linux Docker image for the PaperMC Minecraft server. Original work done by [phyremaster](https://hub.docker.com/u/phyremaster)

PaperMC is an optimized Minecraft server with plugin support (Bukkit, Spigot, Sponge, etc.). This image provides a basic PaperMC server. All customizations are left to the user.

DockerHub repo: https://hub.docker.com/r/oeschme/papermc

Get the image: docker.io/oeschme/papermc:latest

# Usage
For full documentation see https://hub.docker.com/r/phyremaster/papermc


# Edits from phyremaster/papermc

* Added ```eudev``` and ```openrc``` for OSHI support needed by some plugins in some environments.
* Added ENV variable ```MC_RAM_MIN``` for setting minimum RAM. 
  * If ```MC_RAM_MIN``` is not defined ```MC_RAM``` will be used as min and max RAM amount _(this is how phyremasters version works)_.
  * If ```MC_RAM``` is not defined, ```MC_RAM_MIN``` will also be ignored

# Changelog
* 1.0.0 Initial release
  * Doesn't work with current version of PaperMC repo, works only with manual JAR file downloads.
* 1.0.1 
  * Fixed PaperMC download path: Changed from ``papermc.io/api/`` to ``api.papermc.io`` as the old path prevents server startup when changing build or version number
  * Changed bash file name from ``papermc.sh`` to ``paper.sh``
    * Please check your container command settings if using this version over old version
* 1.0.2
  * Fixed .sh file not reading ```MC_RAM_MIN``` properly
* 1.0.3
  * Changed openjdk from 21 to 23
* 1.0.4
  * Upated Java to JDK25
  * Updated PaperMC API to v3 (v2 is deprecated)
* 1.0.5
  * Fixed API URL
* 1.1.0
  * Full rewrite of the script, API structure was changed

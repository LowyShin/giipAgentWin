## Introduce

This repository is giipAgent for Windows.

for Linux/UNIX(RHEL(RedHat Enterprise Linux), CentOS, Ubuntu, Fedora, FreeBSD, Solaris, HP-UX tested) : https://github.com/LowyShin/giipAgentLinux

## Usage

### Download AgentFile

```shell
# Windows
git clone https://github.com/LowyShin/giipAgentWin.git

# Using UiPath on Windows
git clone https://github.com/LowyShin/giipAgentUIP.git

# Linux
git clone https://github.com/LowyShin/giipAgentLinux.git
```

### Copy and Modify config file

copy to parent directory.
```command
copy giipAgent.cfg ..\
```

update your service code from giip service management page
```command
notepad giipAgent.cfg
```

* If you add a new server, keep `lssn = 0` then replace on your service by automatically.

### Register Windows scheduler

Register giipAgent.wsf file to windows scheduler as below environment.

* term : 1min

## Fully automate servers, robots, IoT by giip.

* Go to giip service Page : http://giipasp.azurewebsites.net
* Documentation : https://github.com/LowyShin/giip/wiki
* Sample automation scripts : https://github.com/LowyShin/giip/tree/gh-pages/giipscripts

## GIIP Token uses for engineers!

See more : https://github.com/LowyShin/giip/wiki

* Token exchanges : https://tokenjar.io/GIIP
* Token exchanges manual : https://www.slideshare.net/LowyShin/giipentokenjario-giip-token-trade-manual-20190416-141149519
* GIIP Token Etherscan : https://etherscan.io/token/0x33be026eff080859eb9dfff6029232b094732c52

If you want get GIIP, contact us any time!

## Other Languages

* [English](https://github.com/LowyShin/giip/wiki)
* [日本語](https://github.com/LowyShin/giip-ja/wiki)
* [한국어](https://github.com/LowyShin/giip-ko/wiki)

## Contact

* [Contact Us](https://github.com/LowyShin/giip/wiki/Contact-Us)

## History

* 20200309 Lowy
  * correct when lssn is 0 (New Machine)
  * correct enforce command case of not reading.
* 20200306 Lowy
  * Add [giipAgentUIP](https://github.com/LowyShin/giipAgentUIP) agent using UiPath.

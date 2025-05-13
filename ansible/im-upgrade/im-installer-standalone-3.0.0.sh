#!/bin/bash
# encoding: utf-8


alert_error()
{
    echo -e $1
    echo -e
    exit -1
}


ask_to_continue()
{
    echo -e $1
    [[ "$2" == "yes" ]] && return
    read -p "Do you want to continue? <y/N> " prompt
    [[ $prompt == "y" || $prompt == "Y" || $prompt == "yes" || $prompt == "Yes" ]] || alert_error "Exiting"
}


uninstall()
{
    install_path=${1%/}

    # Stop the daemon service (if running)
    systemctl stop raniot-im-launcher

    rm -fr $install_path
    rm -f /etc/profile.d/raniot-im-launcher-profile
}


check_if_installed()
{
    if [[ -d "$1" ]]; then
        ask_to_continue "\033[33mWarning:\033[0m Directory $1 already exists" $2
    elif [[ -f "/etc/systemd/system/raniot-im-launcher.service" ]]
    then
        impath=$(grep "WorkingDirectory" /etc/systemd/system/raniot-im-launcher.service | cut -d'=' -f2)
        if [[ -v "${impath}" ]]
        then
            ask_to_continue "\033[33mWarning:\033[0m Found IM service without a valid path" $2
        else
            echo -e "\033[33mWarning:\033[0m Found other IM installation at ${impath}"
            echo -e "Cannot install two IM instances in the same host"
            echo -e "Uninstall it first or upgrade it"
            echo -e ""
            exit 1
        fi
    fi
}

deregister_service()
{
    # De-register systemd service
    rm -f /etc/systemd/system/raniot-im-launcher.service
    systemctl daemon-reload
    systemctl reset-failed
}

register_service()
{
    install_path=${1%/}
    ver=$2

    #if [[ -f "/etc/systemd/system/raniot-im-launcher.service" ]]
    #then
    #    impath=$(grep "WorkingDirectory" /etc/systemd/system/raniot-im-launcher.service | cut -d'=' -f2)
    #    if [[ "${impath}" == "${install_path}" ]]
    #    then
    #        return 0
    #    fi
    #fi

    cat > /etc/systemd/system/raniot-im-launcher.service <<EOF
#---systemd unit file for the IM launcher service
#---This configuration file has to be hosted at /etc/systemd/system/

[Unit]

Description=NBIOT IM launcher service - Version ${ver}

After=network-online.target
Wants=network-online.target

#---Systemd does not allow units to start more than a limited number of attempts
#---(set using StartLimitBurst= directive) within a time interval (set using
#---StartLimitIntervalSec= directive). If the limit is exceeded, the Units
#---will not be started anymore.
#---In order to override this feature, set StartLimitIntervalSec=0s

[Service]

#----Run pre-startup configuration script-------------------------
ExecStartPre=+/bin/bash ${install_path}/service/raniot-im-launcher-cleanup
ExecStartPre=+/bin/bash ${install_path}/service/raniot-im-launcher-startup
ExecStartPre=+/bin/bash ${install_path}/service/create-cpuset

#---Let the service notify systemd
#Type=notify
Type=simple

# Do not kill eNB instances (if any) so that they can be reclaimed later
KillMode=process

#---Let the service restart (indefinitely) on exit or failure
Restart=always

#---Python's stdout and stderr are buffered; outputs are shown only when
#---a new-line ('\n') character is seen. Output buffering can be disabled by
#---setting the following environment variable or by passiing -u command-line
#---argument
#---Environment=PYTHONUNBUFFERED=1

WorkingDirectory=${install_path}

#---Export installation path
Environment=RANIOT_IM_INSTALL_PATH=${install_path}

#---Run the service using a dedicated user (instead of the default 'root') for
#---security reasons.
#ExecStart=/usr/bin/sudo -u raniot-im-launcher python3 -u ${install_path}/raniot-im-launcher.py
ExecStart=/usr/bin/sudo -u raniot-im-launcher cgexec -g cpuset:shielded python3 -u ${install_path}/raniot-im-launcher.py


#----Run process clean script before exit----------
ExecStop=+/bin/bash ${install_path}/service/raniot-im-launcher-cleanup

[Install]

Alias=raniot-im-launcher.service

#---Make sure the service is started on reboot
WantedBy=multi-user.target

EOF

    # Start the systemd service
    systemctl daemon-reload
    systemctl start raniot-im-launcher
    info=$(systemctl enable raniot-im-launcher 2>&1 >/dev/null)
    e=$?
    if [[ "$info" == "Failed to enable unit: File /etc/systemd/system/raniot-im-launcher.service already exists." ]]
    then
        sleep 5
        systemctl restart raniot-im-launcher
        return 0
    fi

    return $e
}


# Add a dedicate system user for the service
create_user()
{
    # Check whether the user already exsists
    cat /etc/passwd | grep "raniot-im-launcher" > /dev/null

    if [ $? -eq 1 ]
    then
        useradd -M -r -s /bin/false raniot-im-launcher
    fi

    # Give ownership to the new user so that logs can be recorded
    chown -R raniot-im-launcher:raniot-im-launcher $1
}


install_cgroup_tools()
{
    cgexec &> /dev/null
    e=$?
    if [[ $e -eq 127 ]]
    then
        ask_to_continue "Command 'cgexec' not found. Need to run 'apt install cgroup-tools'" $1
        apt install -y cgroup-tools
    fi
}


install_cpufrequtils()
{
    cpufreq-info &> /dev/null
    e=$?
    if [[ $e -eq 127 ]]
    then
        ask_to_continue "Command 'cpufreq-info' not found. Need to run 'apt install cpufrequtils'" $1
        apt install -y cpufrequtils
    fi
}


install_cpuset()
{
    cset shield &> /dev/null
    e=$?
    if [[ $e -eq 127 ]]
    then
        ask_to_continue "Command 'cset shield' not found. Need to run 'apt install cpuset'" $1
        apt install -y cpuset
    fi
}


install_pip3()
{
    pkg_name=python3-pip
    pip3 --version &>/dev/null

    if [[ $? -ne 0 ]]
    then
        ask_to_continue "\033[33mWarning:\033[0m $pkg_name is missing. It needs to be installed" $1
        apt install -y $pkg_name
    fi
}


install_pip3_package()
{
    pkg_name=$1
    pkg_lib=$2

    python3 -c "import $pkg_lib" &>/dev/null

    if [[ $? -ne 0 ]]
    then
        ask_to_continue "\033[33mWarning:\033[0m $pkg_name library is missing. It needs to be installed" $3
        pip3 install --upgrade $pkg_name
    fi
}


upgrade_im_config()
{
    src=$1
    dst=$2

    echo "Upgrade from old IM version. Porting config data..."
    echo "---------------------------------------------------"
    echo "Old config:"
    echo
    cat  $src
    echo "---------------------------------------------------"
    echo

    esid=$(grep 'es-id'           $src)
    ssip=$(grep 'ssi-project'     $src)
    ssib=$(grep 'ssi-bucket'      $src)
    gcpc=$(grep 'gcp-credentials' $src)
    sdrp=$(grep 'sdr-ports'       $src)

    sed -i "s/.*es-id.*/$esid/"           $dst
    sed -i "s/.*ssi-project.*/$ssip/"     $dst
    sed -i "s/.*ssi-bucket.*/$ssib/"      $dst
    sed -i "s/.*gcp-credentials.*/$gcpc/" $dst
    sed -i "s/.*sdr-ports.*/$sdrp/"       $dst

    rm $src

    echo "---------------------------------------------------"
    echo "New config:"
    echo
    cat  $dst
    echo "---------------------------------------------------"
}


install()
{
    install_path=${1%/}
    
    # Copy files
    mkdir -p $install_path

    #--------Check whether this is a self-extracting script--------
    # Search the archive marker
    marker=$(awk '/^__ARCHIVE_MARKER__/ {print NR + 1; exit 0; }' "${0}")

    # Backup the config file
    [[ -f $install_path/raniot-im-launcher.json ]] && mv $install_path/raniot-im-launcher.json $install_path/raniot-im-launcher.json.bak

    if [[ $marker == "" ]]
    then
        #---No marker was found; copy local files---
        rsync    raniot-im-launcher.py   $install_path/raniot-im-launcher.py
        rsync    README.md               $install_path/README.md
        rsync    Changenotes.txt         $install_path/Changenotes.txt
        rsync    install.sh              $install_path/install.sh
        rsync -r service                 $install_path/service
        rsync -r imlib                   $install_path/imlib
        rsync -r enb                     $install_path/enb
        rsync raniot-im-launcher.json    $install_path/raniot-im-launcher.json

    else
        #---Maker was found; extract the archive----
        tail -n+${marker} "${0}" | tar xpJ -C ${install_path}
    fi

    if [[ -f $install_path/raniot-im-launcher.json.bak ]]
    then
        # Case-1: Upgrade from old (<= 2.6.0 to new >= 3.0.0 version)
        grep 'max-num-instances' $install_path/raniot-im-launcher.json.bak &>/dev/null || upgrade_im_config $install_path/raniot-im-launcher.json.bak $install_path/raniot-im-launcher.json
        # Case-2: Upgrade between new IM versions)
        [[ -f $install_path/raniot-im-launcher.json.bak ]] && mv $install_path/raniot-im-launcher.json.bak $install_path/raniot-im-launcher.json
    fi

    [[ -d $install_path/enb/binaries ]] || mkdir -p $install_path/enb/binaries
    if [[ ! -L $install_path/enb/binaries/active ]]
    then
        mkdir -p $install_path/enb/binaries/dummy
        ln -s dummy $install_path/enb/binaries/active
    fi

    create_user ${install_path}
}

print_help()
{
    echo -e "usage $0 [OPTIONS]"
    echo -e ""
    echo -e "Install/Uninstall instance manager SW."
    echo -e ""
    echo -e "OPTIONS"
    echo -e "    -h, --help                         Print this help and exit"
    echo -e "    -y, --yes                          Answer yes to all prompts"
    echo -e "    -a, --action=\033[32minstall/uninstall\033[0m     Default is 'install'"
    echo -e "    -d, --destination=DESTINATION_PATH Path to Install/Uninstall to/from. Default is \033[32m/opt/skylo/im\033[0m"
}

# Default values
action=install
destination=/opt/skylo/im
VERSION_NUMBER=$(echo $0 | sed 's/.*standalone-//g' | cut -d'-' -f1 | sed 's/.sh//g')
silent=

while [ "$1" != "" ]; do
    case $1 in
        -a | --action )         shift
                                action=$1
                                ;;
        -d | --destination )    shift
                                destination=$1
                                ;;
        -y | --yes )            silent=yes
                                ;;
        -h | --help )           print_help
                                exit
                                ;;
        * )                     print_help
                                exit 1
    esac
    shift
done

[[ $destination != "" ]]  || alert_error "\033[31mError:\033[0m Missing destination path"
[[ $destination != *-* ]] || alert_error "\033[31mError:\033[0m Invalid destination path '${destination}'"
[[ $action != "" ]]       || alert_error "\033[31mError:\033[0m Missing action parameter"
[[ $EUID -eq 0 ]]         || alert_error "\033[31mError:\033[0m This script must be run as root"

[[ $action == install|| $action == uninstall ]] || alert_error "\033[31mError:\033[0m Invalid action '${action}'"

if [[ $action == install ]]
then
    install_pip3         $silent || alert_error "\033[31mError:\033[0m Missing python3-pip"
    install_pip3_package google-cloud-storage google.cloud $silent || alert_error "\033[31mError:\033[0m Missing google-cloud-storage"
    install_cpufrequtils $silent || alert_error "\033[31mError:\033[0m Missing cpufrequtils"
    install_cgroup_tools $silent || alert_error "\033[31mError:\033[0m Missing cgexec"
    install_cpuset       $silent || alert_error "\033[31mError:\033[0m Missing cpuset"
    check_if_installed   $destination $silent
    install              $destination
    register_service     $destination $VERSION_NUMBER

    if [ $? == 0 ]
    then
        echo -e "\033[32mDone!\033[0m"
        echo -e "\033[32mYou may need to reboot (or logout and login) for the real-time priority setting to take effect\033[0m"
        echo -e "\033[32mThis is required only when the IM is installed for the first time!\033[0m"
        echo ""
    else
        echo -e "\033[31mError:\033[0m Failed."
    fi
else
    uninstall          $destination
    deregister_service $destination
fi
exit 0
__ARCHIVE_MARKER__
ı7zXZ  æÖ´F !   t/å£âWÿc] ¼}•À1Dd]‡Á›PætİE	İö'©O¸0•2[‚TV(¾«_ªRë%O§Gx†ÚNâÈõ¾8dùrº4:ô!:şx;¸–XñrU3ˆé'Š %¿ÄU¯‰Üƒ‚;¯	ÑÜèó€‘çË%@ä±c×h58^A½;,Eéÿµø¥9°ôwôò”ÌW€†ö5ÀÕ>.úB½ááp?ÆÀ¿(kÚpW_góÃ»ÿ­dŞœ!Á´íJî#\ôÛ*3y ±`ÜÒİäpTWdğÛï·¶µ.°¾SÍCKF(‚y¿o°!ûğ>-Kì=îó,tÎ¡çmÕr‰ªš7ŸIõ{ÉT/ìÓä”ƒ·ÚêïŠNV}uø°C7oĞ¬º(ıß[)Õí†[Ú—0QF“üà­—õ¦®>,läÍ@+ı'8 )¿'g7o4•IÑnx5†8¸óÓ_|Ï%Sí=± ìfEßUwçs,wb+é¡À»©¯9ë+†¬¾ÃÌÑ<N4m•¿eŒ2IĞèºózÙß†?ƒ!¾·ìÆ>a.ëG’TPÔµ¹áÑ…Û,æQo8œ¡«5öİoÖmüKXäğÈ2”Ô‰;ë-¹µ±:¹öÊ¨ó[Uï‹Gµå4@<®ş`~é@Ò¬UÔĞK¡ÑÏ«8"!æİõ†'¶æçÌÒ‚d‹ê8rh¿ÿĞBÌâ¦òÉŠ`IcjWï³–²G¾¹Ô‹¹æ_/œk_7t_
GKWºáF{Q/P|>9^b¿R–¦À0 f,öæAp¦1SÆ48ÇIÉYütÎv(ù&ôîŠø±$pxø…(¬b„éïÈrH
/æœíH¨İ¢Ë¢°cyL÷taeY]sl¤ï¶àpèhFåjäïÓì3ŸøÅ3ê…‹ÊGßÄ€ ƒ¬g¶)©}a ªÅ§9ÕÈ$µº8‰è÷Œ!,˜¦9,ëNryS¥¾[@'…Óš5£°°áŒæB	¹dpÖí.½´3j÷ç¿ôÿéÎf’ü|kÀä‘n|Ù$pP÷’^ej~ÍÀ’©v\€êt”½7</­ë
•—ğĞÈ¢÷Ø[ŠÛ×ÊİŠ£:°n Pöòa0U6@?Ÿ-Ö1MĞÁíN›6ç†E’ÔA‡¦,IU“FĞU¢èO¼M§/Ç]’¨ ±G!	@B`sı[EÙÆƒêY‚+°–ô	şŞŒÔM{«PÔŠN_áÍGJû£šª®@7|Ùˆ_>+ÔªSŸcjÃÕz[¼ªI”4²5İH¾½š\`ÃD¥L¯Ô*¹ÃObç±Ô€¢uZ¨[ò¬øb\DÓgÃtr1CÍOe\ë±™oIæ$éqJ©maeGøm~ê£B¼jçŞÛş2u”&smŒ]4X#?´pÜÎ2mİ
X]ì-®Ó³^rÈ‘¿sb´ñ!.¼TÅæ/Ú­„R69c,<Æ¾üëÍê(øµÙ¡ˆİØ§ğ-L§˜/‘äÜÕfD.Òªtõ¼X×-xó¾-£1º‚Ô]Ö)) <Pƒ„[Ñ ”,™nĞÉ
Ñ\­¸³k,íŞ !2×a¾İŞÁ!º™“FËşt‰äåİ´aÔa¸ùˆç¶ªÜ’cÑNuÎÇ„¸¿ÎqQ´y~©™5ØéMè«Îìgåv~äI}hÓúIëî¨™…ô3ñJ›Lµ ¸µÛœOæş*k`şå¶É‚ŸwÍ%òÁºûÍnÓıÖöş+¸8§f$v—”Oôë•ÿU,~O´ÖS­#Âg(Ë'ùê]’xn&®îkÀèzÙg÷—ÊÛÛŒèz5´¶ yµ1ÄUtb'D®Lß±^q	ÍÎ`;|ê|ãÎ•†ÊßíRw‰‘·æŒGÉSµÖëdÅs¹aú¿"°"¡‚Ì0C™J¦÷.Ó›ÍÄbØ™KVéŒÌ¯ÉùØÖD.$™;˜Fz@üÊT•¥t…HñËw§`K´	.-W,èö=AY’óÔÍOº¬ø>»Û¹BP^9ÁŠ¥Ÿöş˜„€Rá&	/ İÏêNÆ5y~–Ã‘È!;°\¥ß©,ú0Ü¨Ó¡¥¼LÍO›u*‰¸‰•¥ôVkl!Ş,ŒÖ:¼¿Ğ·ğwÙ¦É˜ˆµıXšèÛTŠ§³¡M²!Mè>aá¥•=e”SÕ®hİ,Ÿ®z&{(0‹‘Ëé¼ÓÇ£“º~Û- 	
]8/fAöSEÔÉWãZUw;Ãşkà`Á·ˆ82Â3ƒ´ç†FLT‹bGÖ7«ÆÀéqêØ-/4{† ÒŸîÒ:-¤´S¹âì(KƒÏÈ†lÊ¾ªbë%§;úæ'¾+K’¦&ãM;cã…ÏÍV™ïï)&Åú³Ëû¾Ã>ÍíÛCıñ®<ı
³Û!ˆØ š©Òji0TÒÿ‡§d~ºJú|úR¬ÎÈ^ ¶•¹	¨Ş¼ë^(m÷Î²›`ÑWè<O4&hãx $J 7qA ÿfxlğ8"z„˜+c·ÇË–:ÑİF¢}	²m×œáSCyL¦élÌä”9Å†m¾¦§ØmDO^„h2[¸#{s:×î½cK;Ø…|è.´ã†xÇŒèÜl:¨º6¥A«=]áKl—ÊgÍnw•õB;çF^˜Ù9ıÿ
u@¯qîÉ§›—|#›Â­^Wüûàåšœ„˜&='Dï,óŠ‡Ï¤Ê7`İıóa¡Øü_=Vw~f–9œº3 GËp­h±tÒ K24#ş~5ÎIøxd/©Ú/‘„?&PšÕk¥/yÑ¾·Ë îÛ]ÅÌÕ°Ñ
©Ç5(1²‚sÓBİ†à+nXüÇ±JWœ.yûßb=şğ€äi“¢%ÃÛ0a‚<¡xW+6Ú^¡ŒÔqê
iYZøf=s>¬q×·-HÄ…´âòáØgè¸.M…Ót^V¤!W’C–mzã~RmÅ‘Kÿ‘QèvW‹D[e§éªyˆ5ÛFZb’QÄ° Bb4–åÏ´'æW|•½˜ó§ôITPOô[~çkşêÂÙ„Ö ¡Y¬&êÇ9‡ó³NT 4¾ı›ABGåÔ´ Œ€t¦a‡Ó³4ÙúÄŸÛ†µ¤[Ç|7.'åWw·*úµJ¼I±‹V‘§Ë,Ã’½|M³}‚×:…—:sÎ¯gU­©³ùsìĞ*f­r@ÂyİcAlö6ÄñYÙgç)4­“]V- ?Ø«io×®¯«£_¨hS¶ıÌl©A
÷<ËX’j¯ºE– W®µİs>ÇŠÆûksNâÎ¶2À5]	àşE4 ËMEW˜?@ØâêÙL,½jÚZªĞXtD¹ØCv‡•Ô{&4ÓlÖ_ö=«Ü‡‘
ø6éLNr]˜/àãòznñ‰K}’°F Liº)—-ëÁµ™‡\Ï“0…à×1›õCâ J«´–O‰«’ëê:ÂVã§?’5<!Ù1Ï†Ø#çz8U†mğ;éƒ”…ùù¡ØÉ!ÂÕ˜JwĞCë¿7şÃv“jŸ‰ä‹gÊôÂp¹}‘òYÑ2¹ÍQ(„='2YJ:¸f9cÑ•„cJ€^eA?½š Hù¾ÆuÖ?=‰6B>s“N#»¸(É*XAÔğÔü•®»¶=Šéƒê›¯ÚT”Y·ÌÛyÕtªG¾x®^AÉ¶›ZëbH\¯z%*»v8ìà=âw{‚iÈ~Uê‰ğí{ôá
ˆ¸0ŸrÌaİoÊ]¦|%’kó4MJºäÖÈ‰^Õ¤A‹0G8|šƒ‚ttcO\û(Rº€•pHkõAÏ‡Ä'9”gºgI2;e5³CàOà=A‹´êğ¨­+·NsµZ¡à©Á‚²L‘9Oï›ut…_8/I£Ÿ£:B _QfÖõâC¦ãáƒá$-ªƒ¨,&¨&.ÿ?&ƒ"óŒÅ‹3]°Š¦I#áÅ£€ï]„ö`	Y%™{ËãŒÔÑ‚z^ê¶ò&J^3àêöcÇc)ü¨;RÆïfnú¸©=AynÎİÌ(3õâÆé)ugtİğ‚Îò^ƒæJö<ŒÓÓuCß0¿®Ûf&à}.³ÒY$4­¹pö”34ûûØ%¿ Š [ëCˆ„`ì?
Y#“ˆh“íx¼¼*_÷—A³«ìL¯o™¶ñ5d@H“Ôjóâ%äÜˆ§R’ØH¦t^¼½f©:îı‘ÖZk‚I/dÕ•Dß[ß• ·fd>7¼ÜÅ#h×QVñ½QT>!ÀS^=÷õñdu$âIÏî§Õ»Ï#MŠĞ¹1¦øUŠ"2èøxaï`¢À­"êÏª—Ä+}á­u$ÔYF‹Ôıj<FûuÍsÊ.ª7­³Ì»
j&õç4sn:D8xüó^|—Ë?¾PCœÌn§.@»¡}E=¡HC}ƒW}>1pceşFGÖ>úû|*"'Ey?6˜‹ĞLï6å5²îü#Ñƒzİ…yP`²_ íBÛ–gè±{ğ^Gt7k¥ı@Z­Œq aİê;®U XjŸñH¿»ªK8	]xMj¨	g]~éi%0ä!m‹–Gr­¬Ä÷	2}´`Ü ÕfÛù„„,·~UrKî–°6‹H(…ıÛ1ËAOåÍÚòBùÄ/°‘íÒ``q3 Âî]İ!QÆ¾çíŞ³`ÖlÉV±Ş†T¥ej2rWîö`rŠˆÇ¦VlŒõZ˜*…Ã,Æ‚‹3©¨¯ñuªGŠQO@ªçÅô$KÃ:æ¬hµVİ-ı7:ícCF÷~~éÂÌÀB½¦1úiº²Ÿ€øØ÷i1tãªc’T+7 ›‘>ıİ0R.c†h%´³Ì-ç^ŸpÀÕ$Ë‡¥H0éK6Ó°‚y„¨‡B|ÿ¹¨X6ª…,ÌEœ~¹ß’uÆB“äšËğÀ¢#àÿ¬+ÿœ&~~ë·ï¶³¨Z¶DøïÄ- J“¡¦¼Õ±ı‚Q‘Â“½¥óüúåJ$úpôZz‡Ó])XËíG‚VvÌÇSŠœr€3/]fzFt©&E^ƒ%2Å²•ñïjÓ…º­ÊwJ¶8™B©äIåÑúüÇÏÖ9Ëõ:gsíx'&§À5ÀJ:İÛÉöxìáR;%XæÒ¡ÁÈ5`¦‹´(˜TZ¡0{Û2îic\êM˜¼»SÎ 
núf=öı™ÀbO OÁcNù÷œ=5#©># % ß³h'Ÿˆ¤§tªhïÉW—wLŠÏmVÔÜUãÆz”&¼—ÍÈj}øò’×Nùhwƒ¸ˆ‚eşH¡bhÅñsqĞ)´æ”F»C¶NúçÁp´Yç\xı•Ğ+íÚ|aÔĞRì«š¢¬ÈùÛLH92‘¤Jìc{=œrÎ€ÜÚ#p=¦¨Ü÷ä¢ä£!;ğÑX,'øó&§	òÆ<G…`æy—A2ÑÜë[,¹h3!	:CàFWê¶'²×©3Fªä5i¤ÿjƒÚ[ÅWĞ»"(",CXÕZDlt­]½%ˆgÒæÍvMã¤ß£"¾¿¯áÕïT‡¿s€¸[Ñ3|I‹j!ùQlsgbYV¦k4„•·*Fa>I\àı¹XüÈıÿ<Ï$6MÃöêúÂ”éAqålNPî3æ¥UÆênºû6f±\vÿÁ‚±®_LAÛ%¿´¹é}ñä‡êğ®ŒEÔ{DÉ[n-£Cå¦z†N,$@ßıÍğA=îôÏîzõªB3(×tàÒS9å<<úI­™ ‰)ã“3¢®¼èâü'€ ‘{|]âıKnëAFÚU+M=øL1g¢.ğ`ŸğN
….,¤;-b“'¬gWˆ{’Ùs–ÈhĞ¢}¶À1¶Ö4=ôˆ}ƒÕ00Gå’í‰1=èa†ÍØ,…ì'œĞ ÉÍÀÜ›Š[Š—X<U=´+ŞñtN!FÛìa½Ör™ccCWD%‡Ş*”NJI}ŠÂôŸpKÕ8S9¡¦WÄ%Ä¡ÌİMæ·L?ºş,…LÓœÃñB3—Ô^àƒïb4‘Ã°b+x6RäÃ!tÕáxí6ZÆ´ºzi=úWÙ;2{C½u•ï}³ÜLJ™qE
SÔ»i«­‹³Hé×¸] `Ê©k5È¶„‡V›™1}şzÏÔ+sŸb*£’¼sÉ ğÅDmj$½"TÄm‰j´Cãvâh¬ôH’ú`…Ñ$1Î,t^†ùÌñA
=Ït!-½âñòCi1DQ‹ ?+è¢n±Ø,‘v¬*¡U•¿AFùRXİ¼é âjlù/ò!7‡©_X(=’™w¼C¿P“0ÿƒ«³D
¹KÙ_ûªEÖõåˆNx°Z+¯ÇŞâ¹Xó4KV‘¦lßM ÓÎ'¡ÎSp9ümÆü¬è—ªÚ_™4Ã£ŠÆn±VáHØpa'æQ…cdğkiàWQS¹ÙIØ²âe]h‰K]>òÕçWnÀW b¤X}«Ôû€WP§ÇÙk39xÈ´ÃEâææ%¡‡g7â~Àß„(™C‹Ü]Ú\ÿâ¨¤î.´¸æÜ™Ÿş!Zr08çÍ2Æ„D›i%\ŸXæZÓlr»‚e÷íÚ*§a³Ú3."ú/O“æ¾Æó\åRı2©Á`?V‡†ÓEóš	›U9GÈ’¿MSü­úÆk©ÿFÓÄv`;±¸ˆ•ÑõíiÔ…—ŒŠw¢Vë psèŠN PmóÛ8C˜WĞï'˜w*P{V
Ì.“¼:E¦¥¿—ö…Å¨O›İrø~'»JŸİùÓ{Ğ omÎR&RŞ
â–¢>¡‘†tAlºQaÓ¢O¯„0†8èôŒÀ
f#±kıŸ_:/(¬!5R
0œœ„A#˜ÎR]^
‹F\‘UGÊı6øÔnŒz4›;‹6w2â´*º+ÖÊö&	diswÄ	“zrcw{îEMµn—A×_ W¥SYtOÛì{+Ö÷áÉ$HC0Yå^-n®[PhÍ‰¨èÿÓÚË]®Ä@~4£5^úK C¼†Ğ#ş?dÏ¬YÀ¼šrA+…"JbÕ4j£tró“®š¡e@‰"ŒFp[+UXUîOÖ ŒhACgÂYCöD¸p<ƒ„”İá6
á–
‰`áÀq¤µ ğ¸â«·ëã¯·3x^8ÿYñ(ºĞ½%àLU‡S³5jFÜeâXã­}³WV ­×ÓŒÙÉÌä&ÉÎ‹¹ßS`
#º2î,é6ª®Å-ğÁÍ0åÂ3Ay&U6¤˜u´p4€åİNeñ³$M!ç©ÏC%™jÚEÏ&R®tÿ"^ÂØQ"ñJQ¯‘uLâÌ?]êÈ(w„ˆH F­eˆÈ’í.ÖÙéÿ0É
'˜ªæM&ˆ":‘4áòø{–´™§b^àbEw.ÄİŠÒÏ3õÎ…1;G\‰U¦²2×Ì5±2´‹7QŒ´+<E»I×U{'ATÒa¯UäîÖÍùŠÃÇ‚æm£uØ/6ñjŠ¬ÿŒ²áDì"êtƒÃ„¨§º×l¨¹C½X¹Rò€(«kÕ >îÅ èäú°#>„r•NH7=§WR¡Š@uÁ‹…-, ­f–l®	©~Eü¿_ ³~…ĞØ}:r’öŞî6Ó]œÑ¤9]€aØœk8$Œ"" ×ìgpÁÇA§á*µ'	‹¿ğĞÈÄ­‘™}{AÚ…l¶.®Kq„ã¿ŒÛ,wÀáüŒr‚û½§€è6öüİ¨©i³×á‘’èÂ¶w	Ì”ª]XÖ«9Ç‹óÛ†MªH±í2“]²XĞ’V®ƒy±0òj ´Z£\±ØÈkC¦»¶ i/#%ˆ‹	W*˜¿ÎÀaZÿ‰´³ú!†ˆ‚‡J‡©€¸—[¹¹e¸ƒ¹Ã½. •£ÂÚÊ*QÃ3Ÿ˜¤ëDßqzU›Ì™ØÎQôÓJ©}? [oûqè:P‘…Êõ²ì²¨8__ÎŒÄ™MƒÈßá‹T˜¯±{”/3¼Ö»>s°9åĞïU,Ât¿¹·ÃŸgw+-Û¸ˆÉb¡t†œ7 £+^"İ³t6¤‹ñÖå’»{{ÆV{¦ñÈ©>+ñ§¹#RØùÏÜ‡Şö%;õtG¹?M”ç‚H,˜®ğµÙ¶NkC-¼Õãşá¾Â«ÄšÄ… ÍÓVÅé{ò¯D'ÉTÅ^û§GykQ®‘šo/¶(Hı`µBk˜)0ıC›îœ«yú™ZîI´êàÀ`O›à×9ŒFvF·ª•3ÁX˜¢Œ9”GhÃ;F8£àÇeILîd5àç.¿Yÿ¿Åì„9ëÜ%03 ÖÜMSgßçÎ»˜qwÆc™³Eçˆ(ÄAa¹‡êÔnäÉû%­OµÈsöù‘ÌC®˜gjQØ\Çî¼Ï0MûÉÅ2^n„}â·kÉ¥B_â³$	H¦éâÇb¤¸€Æ^­Å¥‚S9ì)œÌu$Ñs6„•]¦1—3B”¤FÕÚ•¹e	¨9÷.Â¯ïfšdç#+'ø}v}3ÈG­êÄŠCîÏå$‹B½“ ½Ñaw2»Û'ãöf8½VùëÑÜW@èŒ² '5é–8æeÆñ]šœo^'<š)Så¥íeçèšıŠ#ËÜ¨™ ÔNk?M¢¤÷t:9¯È6Ï_ó4æI=mO>0ÒŞ%&!V¢sK½Ùé ¢ê &àG"•‰½$	ß/|â’|ÒÊy4—p\Èêã™é£·22M¨†L@m¤’mÖ¹
d(7õûZÇ°Õ3":Èuã±‚81Õhà
çäa´gÂâr¶Ü%\ÛIrABNê#œq8_EKğìOh0y¶ÿşF‘TPšmë|êÀïgBP(§fSö’}zâË°5#û}¶x§OÈ©Kåñİv°ä(La±û©Ô;ªCëRƒ
7`0ˆÒ“Ş8àšÏŞ›à	ÉDDj›uÿ›M'àuÎyÏÓ¬}­‘ü©÷–Õidğø§Z«ì5Rş®«’¦amE¶‚ğÉçÇÊ½Ü÷•( ©nBX)³êŠ1«ÒÒ‚ëæFØ¢¾ƒÑš®™ĞâÉ=Ë)¦<f3RcE¨V	ª‰©	}ºµfx˜yÂ €æ(¸Ø¯åÙWJØ­îXx!:_üíéna/Cïg˜í|?4o>+‘ï¶øß$‹²aÿ×H`"lµ<vyÇ}Eò¼7¢3ˆh*æ“±³Çš1õ‡,ÍA¯GÕ«.òØ/Ç@N"İˆÀšîkğ®®!—u£§ "ä@é
UgÚáÛÌ,Ì>p@®^µæ6JÉå?€¾ĞÃÈMdš©wùÙM’t¨zß‚Dı?¡©\¥ëş%%ñ$âQ ±Oü£¿Œ9†©Ûlôò}²ÙfÊmÑvG¶ni(7‰^tó¡Ót©\£Ü&§çâgÔ•^/rP_¬a‡Íñ_	5ñ;=aÓ6dt·ÊË‡ù‰°û†£U5ı9#¦xZeZ5A¾B=²í·ÆuÁ¿Ùgé'_Ö8*¤É4;«¼Ïö†éQå¥N-…Ok¾š_‚îÿIŸû:@ô;¶[j†%úò1ë×_²EgÚFØúÃgÙŒürÁ#®õ‘¯Ñ'Çõ‡(FZY—±íñ#„šÎ½õ:ƒàwıÛm°7˜D¾d]AµÄÏÌÒJŞ†¦œ¬ŞD˜ñSC®A…¼(ˆ¼›)4$Ã›}^HÚSîB,
¿{¥s°vŠ1áSÇNÄÁ]H¤Df,äÎucâZÏ3>Ò4Î†q5´Áf§TÃÜ›|ÅæóÅHàjPÍÎ
¸İQó'{u	¹5úb,Åk˜”AS‹-ˆÑŠİx:íÃ­y)Äæ}Ê¬4QuDEÓ›vÿÔv€UÄùEÁ3ÿÚ†Øò¥„ŞÏ¸dšh¶Õ³ÔQáíğ/íâ"Wjd1"8$×Efûj8‚àl‚	\JŞ”†rÌ9t°,É[¾ƒ+éMß°OÄ¢;óÜHÃÜ»ÒlÛ áéx\ 8Çæ ³ã]
[Ï Äïš^œnÉ_ùéCûÄ¢7í£ŒÇ.ƒ0Ò-& íaß_Š®¬“ßşO“µ"ŒMNIn-|aÌÍêy­ß_t(ÊU™ñqKiCksË9]OúÚÛƒ5Â¿&ÕÙ·wì~öó¤UéG.WhÓ3ÄÅ8˜@j $¬Å9ùCH‘Q‹Ö'ºt¸NÎñ,=$£4­yÔ¡t’ÅH²q‘ÍşÆLã±MÂ÷Ñ¤™Í™×R¬¦©Q>»6kp£j¤Õæµ¤ñ™M5Ëa‰ŸÉ‰:ƒI£uêâ.˜h¿b¥¾Cóp*/Å?ŒîŠ§2(˜Æğ-C²Öß]0°€¢F÷‰Fåş05œ}€m, ƒƒŠ<J0Š”“B6Ç;·¨÷J#_ÙFÀø
\h~‹b^!«£¿sëÅ”b7ÖÕoo^Í¸˜dm,W8‡ÀĞúo=Ğ*ğœÊ¢Îè´?>=™„ÏVBBòBV‹[ÑğÃ>ß¦²º·[~šù]šçPıR9~¡ĞÁrO	‘àXÂZUGÙ†	•ğªÚ ¢L{ÚÁÊ5ìREØÆFgÂ:çÃj*”	j™#ÜÿjHÂ_\Ş¬ƒ4‰ì;
½jÔ~®l?d*íhnlFôK}óz‡ŒFı‚Ïå„r gz_(vŠ¹‚.áTÖo¡ø¶1ií+AJ,B à^êÑü,¡kÉã	0»õ¤JL¦JEâï=øÓÉk´©É…T1óBvè^gô¹›']PdNËêHŞ¬Qšìf3=±°šàÒ;Q\ÓÃ÷?"ÍTëüİGòšõƒ£7b™	ñëJÕ÷±wd‚‘8ç¼ãv6e"êõRåWøàß—™ˆ“%ÅuÛdX7—2PK˜^Êù²1+¾#´zßÿ¼i¼Ì º¬,_¶$—–„Ëõ©¯x·ö$†-è$EwñŠ£*6øÙ±¦Œ7¦15†ñ2#6µÎëºöĞ<ÃùXhpNñQÚKˆ—Ã\¯.·¶)ÖıÕ0mc1ÌäÄ‡›à°rMyûE¸ØÎ·Ä	]Üÿ•ğNÍùşdê-nö“Ç¹Ë·¶É¿uª†¨»%jŒXyÏå{ÈFà)HâŠJ!|Æ%:+0}Í¯×Vøí„pS'†.Â.CØÃJÑ:ú¶œg'°ñÂGõ~]æ÷‚I9qğNºªõÅb[>’|Ó¥“#këRûŸŠ)şLÁy» 5’æ`{\Ø ¸Ü|í¼½Ò‘*mğë·^?ÕZ£µôG„õ½áÖ(2yÃ·°¯x¿ç>5×˜]½'«ã§bOŠäO3»O0%4+‡VZªÒœïˆâ1íØw¢tù@³3;Ê´<°°Tæ”î±™\FÄÓ^¶¡¹ä¿"=ş×A25$ée”%«şz¾rvUbaÚ_´äyÖ:®¾½’ü¨›a]¹YD8¼ì«7±¨rœ¾^L¾e(n¾/nĞµBÜ<W}]˜Z\PœpÂÙÔ¢ı%z.ĞRÉ­M¢ë·ø[>8ƒŸ©Ç-çeO¹úáºËÃ+É¹ˆ÷Şò-Œ)	:Óñ‰ÄÍ|;{W°›ªËV£N6Ÿ/ææù›×3¿bÅ¨ñó&}e»õQ	Z­q¾‡ú÷*dgš6šTümÍ1İ|R sµöRÉïù3,ßí½ğ·äì»ï<cfY'7C7GÄk§‹&©rÛ=)İ¦s NÙ‘¦]ÚjÆÿ¾r¯A¯Œ9]-Yğ—6ÓÛ8ôáßà<n•!/éñ“ÎŞ´sû /”-1¡GÃnĞ¼Ş×Ó°ŸrT›¹ŸQø0¦N—‚Y¬xH¡q¸×zB•EZ-üöbÚV B
´d™|¢&ÀÈõS¡Ğ§ú²×cf™K)èâÛ=-Àë"@Û]EãÜC/«Ô*•Ém¥{0}=‰eÕSĞ´çï³ÊüCÔÉsÅöÍİ_wØ(NÇO÷	şâio³¦>ê«Õëü:í|´'P‘_À`QÖÖ:ãFâ´)@wû»1õÁ.#‘j³	cÕ#ÏÌ8ì:ïÒ¬¿‹[Šq©½}.ÆË¾SUB]Õ§Áı–ª$3Œ}Yº²æµæò§.>6·Æ±p|¾û€yìw	Uwq|‰aëLù ó z£—ë¸* m…PÕº?Mm„y¡tåc]vädÃl€	†Xr S.ır6h1]%NX£ø¢M"hæêëN¨AõMEù@xQ©øóhÚîao{2ĞZĞ”)qƒcX¦÷Rò©>²ÓÏö½XåÓõYÙ¶Âı¯!Æá0:şVEõ‰èÛ{?i@ÅÚw™bû«|BŞ(E'‰Ù°¼8·YÔHx/ƒÙ )ïàó– ”	‘½X¹üÄ½Î}4Ç ¸PcfK3a2‡¼ê‡)ïçÄ}èB˜¨&³
³†üAtwLj:mëéî,QÌg²Øb18!¹s¼=„¢'³–\»œø+N¸QEç‘¥ ¢P<¥—»N±N.`§Œ.ÜoŠYkÌ—¯¡ µT¨¹éFÂû&ñ–-ent[°è»¼âäÛ”ÇºŸºlñY%Âêl‚İë)ØkĞ`Yfàæ÷»OR_Ûu(Ñï@—}‰ëÛ*r•á™©BoXİÉÖÉ‚¥ÜÆ+NÌ&N]gÇr|˜Ü:=À<	JTncp ÈMÎò/©èfê#z¯kp–ŒMBÍ@H#RïP8‡>û|>caK[kò8w7è—ÄáïpW$Ï¢3W_AYt’os?H,às¼õ€'À9Ø•›ú›ÃÇD,‚?`?B$0‡¨Ép+]¦öıÄë½;+ªjòB"OÃo;÷
àÙ„sÉê¤Ärš\¥ÈiÔ(»ÏçÈ²§ìv·À2D©`S3P·i.ËnÁËê¡Ex"mà'¯ç–Y%$ñø”z%´´›ö,>¸1^¤¡)³ô¥Å“uD_;×Qv}‚9÷¼#¾?›à_0=\µ#˜ˆ÷ Ğ2İ«ôô@l&2Võ²Ã°ÍNx/»“utfÏÀÌ=DÊè¬¢ØYâPùh¹mÅñmŒ²U)ûE&VdÑ8¿+ñ{#‹},¶BË1#öd?|Ğ2êöøP‚Y
«Ñ—! EÕjå: íŞßQŒ€X·só_¤ñéò¯U&cbEİ]E†SDÄÇ]QZè¸?‹wÆ›,x)uÚGwìe"%º1»—a <—ï½®¶Ln,H±”5Èz51Í—„àíVäş‡=P^CÃ–ôétßÂÄ™/'Ò(*_¨Yo¼²P.dĞ’ïQèÃ»3ÈxcIE($Á¥£×îv\-K­=Íw˜-áÓşuüš¨¼Ò»ÿ»µWÙÆWuênı@…;é¯z~4»”î©•xê½u˜çûI¶!\W¦–Q‹Ò?œ–g6GcÑ	}@8w!ã¤Åæ<Œ—©æ;r+R<ôÕÍr\SP©!Ÿ‚,È(IzØãeÅE6« ø±Àq81„£Î÷€¨ã,îU³™§ö³ıNaY,9“¸Š–I&&	ß9z®^»ğß	IÁ”÷œ,A‹krƒ„;[äÂÎY½6ôüv²ó´•é­ºşz(@³ sÃæ:AHs³E¸Ä’[ª´’!TvÒ¢v¥®eLèÎB®›w²!G´¿}Şº€è|ÄlsE¤õ*r¶7Nµİ0Y]Q İŸ*ÈíB•gÚğ-ó[¤jx1‘Ã~dvĞû‰(l+z¡¯ÕÌIipÔ!°æŸšÇ´»â#_Ì­ ãª‹1ƒ¨c"º&¶c1CG{)(dŠYípSš¼WI È2Ü~ÀÛııĞih)&!€Ï•ªH](„eÉ•¤_[çˆDƒä|SUv°˜<N×MúşfÕZ¨ÓmI•73¶Ô¹£ÀA¬yÊHO˜:êšŠî‰P_UKo¨©Ôò\,!šJA¹¼‚ÄR–ÒŞ$ÃŸNç•Á¥”°gC`ØkŠŞYXmMßZ@gxEØp èÌ}Ï¾Øè«ßotU-Ç*Ç_PcG/ˆc¤ä¼TO“
$ÄQjq\îAö n'_kÏKü.`Í¿P õnİ(•Îbxßš0çë‚W.PlO¿É'	ŸJj ¾½Ãß¬´Ä%á%_·…>Ã$•KJbÿØsÀ©ıDT´"–@ÎsùÔİ@–Ñ¤,Û8õ¨¬ms©ŒÎ/ŸEõs¹<ñ*ôÓµ£URáz­ÊYïN?¹Ç´¶E_,‡ËÛabE¾¥~>ŠÃºiò9nuóîæuÔæ±œ®^lÀ…((I‘ÕèŞi6ú72³œW“t´²¶ ã‹®ÿNÑJÀPµÅ-¥»»¾ğ-ß{e¹?šøU© u×"ê~Ål¨ÔŠ„şï0Ê˜&¨v³…ÉÂY’H0ÉŒ9§KÆY–9 ü¾éF¹Jr8SÛÎ%Ò÷ÊƒŒüìr€…lµŒ9aø2¨	õÙ¤HĞêcÎz´i1Î9zKK’OèMàK)È„U½13¬™eO;»èøãvJBñ+‘¾ã·ö_!;ÔİË­uÜ˜0Ç~ûîö”«°Ÿ×”.å›aò[Ğ
QL:
ØÜ°Çr–IÇCåóñåË8ZŸ,ı¬kØûŸ{`±ŸfM»_î(•÷&qm—|‡ƒñxÍšÇCTæ$>´	3¨k9Q„ûÛ§7’ª3hF¼Áàh©2y6&i!Y¯7½÷Çzë3wc°F¾ÁìYîR«ÀQÒÇWVy¸•ú›c^ }•L±ìiÕ•…Hş'I{ù—œC”JCê·×ŒíJ·ó”¡g¦®ÁSâ˜ ‡kVfò8y4ó03­ßÊ°Nø=ã"£..c÷©êïñ½«néÚ·O1õ±g—RÂÚ±°E7_şVLÄD&ğä-D9(xÚz•­ÿêõƒ>ü~ºŠìGQ¸|®avrŞè©1I27ÒµQHlñ¶¼ƒCt\ŒI—_’…—ü-ä(RİÖÌHXU®šf¦§FÏ¸T[õ Œœ]RV¬6”9Ìj„RF¶ÅÜ¸÷Ï	ÃÅ°%ÇÖépâAg>è"Qv„ZüñcÉ¦7÷º8ôèÆ›Õùeù'(„¯ÇEy”MUa+=§+c‰ğÒ1×£qRD]ãL¬7_BşîBñ‚7ÈL^ÇiŞP®-hG¸Î4€”V
t½‚é$ÛˆÃÔ ~‘5¢]:e<ç0)şp·Ùl?Œ˜·' ãé]˜ô2VgûñyG	–¹.LIİy½“_`¤?‘ÔJ¾¦xä¦NnA)Ï¹HùÛ*'bAÛ>3ŸúD"BPŒCõ‡<TğúOdYølÒƒù"Æ_nÌ‰ZÎ$×kÌã~EM«áxjşš¦Mßuışƒ©S†M }Û0´ÙŸ‹F5Šf¼Uy !•Ò…X3u½Æh÷qiÂÖ†ã×
¾,UY)*±€ˆ-ëYMOÀN?:—Œ¤„à¥¬Ñ‹Ì,=CÆ â-–ÅIï¤RdÕé-§SûI+ß¹Ghš®Ú5Ñ

Ïâˆ4|o„ûºIK6†¥E3´ø`Ü±64S¬£¦2ØMHJİÔVJ¾y+İÊÍò×ªÜLÜ9” ›4¤†sìµSØŞ~JõsYoíu	‚—ObÄ“æ\ô¤k¤µ[òÏ&5BŠE\×`¹EĞC¼‘é…x£`C–w¾`fn„<Ğ†²É»,k­š‹'J=0]µ†Hhç
½ kÏj<KÎĞ¾’Cbz2•Š-6ly_(†a«Ömï,ÑŒ»Õ˜é°Y|€XcĞãn°O¿C†·İ%yŸ-€ë™}’¥$	¼Š>¶Ç”ÌÑS´ˆhÏo6~¢âN³bæ 84M¡š`ÚC€&6Öä'Ñ@‰œ-®é3EıÇr‰¶Æ„¬1:/ààãë30Ü¦áÃ©ˆyGÕH“ÓÔËúïòÈĞÀƒM’ŠŸOÏRûÓ2E—j²ö6n*ê‹ò~
%V¿·)÷/Çlñ1 ½x_¤åJÜ |Ø&Ş9t"‚
$8î§‘0±˜V)QİëËI{Wv¹>SÑâ%ŞãàÂªÙE&ŒÁf¬ìVI½”·Ùye<¶$æğ2Vşú£¤¶’ª2ßº¦„ †³,wæŞ‚ MSµ«¿²ƒ)y—lÍ6¾ÜQ¿É~_İ”—“&ï©M‹›w:€Ÿ¤ØQQÛqD$_¡õ—*Vš–º9O8×»ç97VR’ ´á¢G±m7î±Ñé?È‘Ì”m«¬}t4€|ŞÔ.©Ë5>rvê…î=Eÿ§×vûhrAÖÈïÒIrÿ?3Å1V	oƒX­ ¼2_aŞIÓ<_“Î¦ğÌ³aŸÉØ‚¦TÌ‡@aÎÀô#ä×X‚Ñ½–˜z¥î€ªÅ5EBÂ‹6eJiúØê÷Úİ’ B2İ—W‡¼?ÀßÇÛßŸ4m½$­Ñ‚ºÕm¥ı_î/1Ãà;#0h‰¸c™+ùë#Ê¹›î|Öd	éTÈX–2>µ;n%Ağ6^@Áí^Øq1şøÚnğÎºøî“OäÙ]¡bD-%H4¢ÚX˜‰)Hşÿf´nIã‘£¬#M’P‡ĞX†ÒsÒ¾
D>¥‡Æ¦6ùOM²Ï5'ÙßÏÚjHêun-ÄoÛqÁ¨î]ª™	Øe¶{EO¬š†õj±Íù‘£}Ş‰“RJdSu.¹®f×"ÌİjàK
¶èfK• ©ÔfıX¤6Unõ”şAºÇ´+Ó'¬Ï™¯9C,ôs`¬.b’ş3<P©•.¥êF£ZÅt¸?Ïa–5r•ş«&:†—÷]£ÜÃt'Ìå•¨—3Ü™)QF^zGÙŸ8ĞÑÎnö[µÿíåC»âÌgãb¯r6c…ıXéº;#çñÄaºŠZğúİ!°¶P,œùñmº=Ùr*’l¡ ¢ †¹(v=tå™¼‰¾¼W«Á ®¼¦ï
0°"õRµûÓy*ODJR=Ÿç/ñSBÅuj|±=ÕÓ†W½{XJg‡à¸R¿¹ò_¶lêĞß›®Ü™S'#y¨’í¤rğ]ãñ‰#Í§d¡®Ï¯*¬D%›÷¥~ñ¾‘”AÆ†0™ÔØøYµ‡‰Èó%ëx˜ßUšÂÏlëúÔ´q¨Ê]Î%Ö5Wv]†„6ú†]¾³ÃÅ¯"–fdÓ´¥‡6°¼>“-{³ÍgAa	ø^+UğxÏ½½~¢„EöË}ı¾æiÚ-·«h³e¼é1ÏID1Lsg,8t
I•	q¸ô—j6Y»U„
 "3±£[Ä:tïO<¡×üz­ø”¹°›
ÅsÁ ¼»½Ê4¨g±˜æ‘8ÔaáÂz¢Ğš€çRÊG†`6ù´‹j+R,îêÈ=OÒĞÿÜ¶ø’'F¾ãâd â@€œ³ÂÌLPbšÔÈÌ<`{wÜW}Šç€GØ¾º	º 	u“glu›‚ûO®Á·cˆŞì_’sl[ÿ^Â§ßç&-„g?7íßZDLª¦ïq#Şo£aR„V\À¹MçY’Ó@æYu•¤˜¾ê¸l]Î…ï@m Ï¤-ô'2KcßQ\‘SÈB	ŞøÎ/aü8ş¼3lbcÛÃ°‰¶g±&<ú£û‘rkšü{¾ìªö)}ş‡8Š&ßOµ^ So‹B jŸ÷§>©\mİs>z~‰¡q^aé.Rá²åå”ÓskòvSL¦µ¸íÎê™ùMÂä…+G<g/Bİí†äcºcÔÂ¨P”À˜õ€zG‰h06İl¦Å¡V<½!N“‰wíê5?D”xëí;âÖøc«˜Yq7w‡ñşNV«úu'ÑÙÄDáçn©®F¶&¯ =/«“ìpà{…¸|#eŞ½‘¨*ƒƒ+¨À¶ÈIr< œANËûËui£È›^ÛûÃ0ŞìDÉ~$ZTWÍF!¡NğÂBÿa‰”"–êûQ­DJtr;=[9M_ê-bÀ¸õ /˜ñ
=ëYˆt9|tòí†O¯ØOÆEÌPTüU¨3¾-í«T©<£ÅÓ¶$/^¨÷š‚§ÇKîƒ*'³éì¶šµ%4ÜôE¤âñåQª_Hé‰u›Æë€·6>Õè¯,e
äS-¼œõ¹ğ«%vP)qX86–ğxN	Œ·¹1%î*àqX‚œŠÿ§}Z^S›¼k„§áŒ¼7B¥PÔ<Õ3!Œ+Ì6hNYE@ƒR‰¯Bèzù9¶ëä»ì][I?ªoÖ4jloè­PQ¸•³ÎWÜ{,”]BÕí¹¿İüƒ.Ò-[ãÕ1Jùzó4Îİ¯Â^Ğ÷bMH0ú¼h‡Ğd±Œ{ˆ„©ñR_Ëvö,<´r+ÕÔÜV>æƒzÙí§cE}ÿ#A fş:è3ôÕc5¶@Œ½²“ŒŸ]&3·]—@‹Bùl4Q8÷´ØÅt^-¬ÛPr—B-@÷f¦]–¾+bŞde(äBg¶PO¿lhbøã§Êğxõ¹û¯[“"¤·ƒÊŸ©—!<"ÖíÈáÕŠN´…»PvÎ’;µ<ëó€º:h3èÿ[‚Zàö`õV\ı©¨º~Ä­XmLGuwÀË¼Ö•¬Uë.L›‚kÃCÔ!jŠ™ˆ2wÓDòs0­E¦ónËÓÆß=a¹aq=(ÇÄĞòÁHY3ÿ›CTnÃ##˜Ğ2Ş2,Qø¾_ü½½øÆn B!äUçíµy z˜u*ëó×WUĞ(E¹Y¬a)°¬ßûÏ·Y{°xšhTëuÉt'ÒYjpT¿ù;J?¡}}Ôm8é„h_ÏÅA8½Ô
“ã9³ÄqNö°|ƒ;‰ˆ»Ì‰ÓÊê™ª­‚‹Çi£Š«6;†»Şc¿¥iÙÅIe±1ÃşÛ
ÀŒ4	r±5¹ú¯øINXÕôÊÀSäU|:ã^]×£u$ÛÀdZ¦k3p±A9˜å±Õ„¤ÄØ¹¼•*é{Ê²ƒÑ«“M¡¹9İf(˜“(…qœÇ½¢3ßİ—k)ÅW‰€6LR•&±ùCaÊÆgüÕµ¼Ø–Ó‰æ7GàY=~ øóªâE&}/JÂ]ëÜ :ÎúÜÉ¢Qe‹^\Î÷sj{l"±º¦AP\ã¢Éi&ÉHÑ«ñ7óGŠó|{ÓÓ±¿nSSßx¡õÔÃhu[ ğpvwñ‘½Ãï5®½„0*!ÖŞœ‰[9/×N–™šùh7“”Eª½äşj¯ßÅ°8“›m‡ÎÂKÀfIÑÀ”ÄD¥Ôƒ§¼Ë3€›qx¬äÏzJ¸(ÿÄ</w	zp^lFˆäNÖ€Ğ$Ä…³mE§ğMˆÃİKc7Š¿õÉ$	>ı½Åë-vÕŒ0,€':f9	§S®¿òÂkTáìûwA™H4ç:ïÍ|%J#.‘—şÌ]”ğL·ù¦$ÃßBÍ;¾U.¢S
¥ÍI Dåö˜‹tâ,–ê½$y¶w(ªµ¨<ö¼•œ3{U•.öÛf+³*%“îášÀÔ’&#R$ıŠÀ¬,À„#…7W Ğ@aE´Ø‘g°S§¾ob; /*‚û¹İHopX)îÄôê’»xä·[Ò«ßÑY1›>=…6eÒÄ“Ë°_mG?ñpvMAÔwÖ[¡BàÊêıãt5‰È¿Aûq+Ğ­úÉ±‹è?†U,tÚX.ZûŠŠ¿Ï©â~-„ˆ‹q~Œ
ì‘|×Î]Œ<|j"åê›çú¹U¸ÿ^¶Bú2¹öA¾@l.İIUC„@
JCºx‹¦1ÕÀêÙüÃ*Çzã –ù—u³ÍÚï=Ë>Ô(=ÑÑğ¿¾=|‚´ÿSÖ®ºÜÒÆá-Ñ=.ë‚[u@º#ìN•€.Èuv(Gïü‹Ì;š·İCl‡•º‹pˆÔa$Ë	bKe÷ÓÜãEC5şJ€qñGœ¾SEÁN<sjÉ  hXò¶ *g”ä‘j3wú2µ{4Ô¹GƒnˆÁAğ"ÿTñgÕs£'(%è"—Pñ‚Y?ÕëŞ@]boH…§(aÚîì#uÚ˜£ıÌhĞœVlö»$T–éÕÑå©8T0Ÿ›È>F]ºî…ş-Ç9tš|Ó¨Qù¢=Ü•.KqôåücuKÈÏ~ÚçŸÄ>á¶àÌ'š’7BâXÜs«ÕÔÙÖ)—>{uÃC×ÁÚw€Á…Á ºH~—«cü>8Ø¼yÓuyBcø·Yó³ÛÓ­Z„WĞà`îú¯âÔ³uÊ3§í]¢©5êNkm…¤‡–ûan9‹M3†3:ö2Ç¡Y"TŠy"ÑB<¶h.„G~×›^Ñ:\útˆÍ¤­ç“6-/ú)ÖÚöV‹.¥f*šûäJ.X…å™Q™n³=oP*®Æ Ëï;İğixÏà©à°ã£ÙNÛ˜Ä—ıÇ#r±"#½”qür™A&tzz1L‘Æ¶5õ.ÖnòåÆûy<Fn’şP€7VÜl~ã­ŸbóH¤‘@Ù
n¡ÒüÀUÉi†¤@ ı)ËçîÌâV}ËqMÚÉ[Yİu0ûÊwãÜT6œCZÓ½cÒØvk»;QÅ ”â‹ˆ¿‰²Ø4>İÉ€â«“Ÿ|Ì8!­k®£–÷­ÂM%+tƒ.×‹.×úÒËl­_Q#|…i'®GÛuNò$pˆ“{Tz£ÚJcÜÂÛl%Ş2N9ÌO}öéŒºëëHPIùø¼p|*[_^Ìm¯Ê«[Å6qñ{à	,Òd€•­ƒŸ©F<w¼¥ô…€>Dú¾‡MÓŸÓ—.]ÕÚ2¶ÒA¶=Rq¨lEŸğ(’ëR-8C¿—mªjv14ÇÍ“‹óYjRÚ·ç¾·n[2Ù`÷—®»–ñFĞ:n!ŞJWëŸµ4¢./´WĞô«´Û~ĞX#”V\u¶_åwü.y|vi
TqCIWs’81¨á6F!>ÃÍ>›ŞbEà°	?t?*Ì¢í–m„ËDÿ”ênqÑæØ1ğa€|á ı	á'[°p¢g‰ºù`z¸
-ø†™ı§~lH¥³×Ï²¨şèNş±¢B@Bì?WB b ·¢íÒ—³ñ‰æ”İÂŞQÈæãÚeÂtã"—ŠJ´:Fn©¼iËkL5ñ¬&–z[VƒÎî¨™òò¢·õô½DâÉˆŠ¸u”:™oŒªÆíï	W.€*!Ä`_Š°S$n€Q¸®#W²‡R‘Ûâ&ÿ/'„9MMµ¼iÔãÄ	(öş˜‘L²‡Ñ\g2ØğYöI³ø;J­È•D 1ç}<½ğ­	j³İ1´wlãÕÊòÂŞÈ¾H}lêNÃ„nŸè+‰°Èax¼},Şï”j+uìà5L4ÿö+ ª0y_¶XçògimÔ<ÌÀá>KÙr1%×}§|¦0'zï¸„C¤{íec¢Óö×ãcğğúÄæŸl&àÈ0ÄlÕP7†ˆ~ß¿Âö&zó'¯f;g½¹©ÑƒëXìpôöBù‘.µ°± â¢e]ÊOÀAZ~¢ı!Ò+ÜÀ—XI¹vŠx¸Ÿ+p\›Œ›ç¾Rˆ/æ O»µƒ‘¹©ˆ]
³û)¬7>÷ŠIs¶jwgÄ:òT×BÃo“/†ØbZ™9µ÷NÀ°;#&Ôç|Æ³*Y‹A³5W¬İïáõù¤k“ÁtjÜR=‹T~ùÖ–W‡Q
c’Ä4†híñÕs&VÿØ€úÈGŸ+A#›Ş"óÙÉ{éU 6#{- ÌJ3nOïàVÿÅŸŒ¶Åis—røïÇ]ÀÊ5^Ô§íïÍjRX¿&EŸ0-C_­Â¢Nædg$3U(ùÌ±‹^ó.r)Ş]iYqt÷§ÖbåZİ%QDY¢G®¶dÅF0ö²ËÎk`bĞCÜé*ºì(¡³äC	áï‘KíÙ­¥Q¢_T‡#0
è[íYhjı<^†‘]Å_OŞ¿8Lûv‹ÆK?Œ^Bcu™Ã>Œ5:İÒÚsB/ºmkå$Šêijk™Æ¥´=’¼<Z4q†¡B²w` /¹ÉÈÈ'N‰2Öš_-°HS'È<§ä.qöÕŠønÉä]pëfy«3‰öBkc“ÌÖø5J­ƒÛíÚ¢ÿP(¤/æ¡æeøÅj7²<¹|¸Î1›Iih›"®Æß¯Ê…I’UÒ	ƒ‘°7´Ï¦[=J%ÈLa¤éC8'~ >İW’„Ñ—çÖ`\X)¤VÇ#a*øÛš¨é"aşe~@õšÌ"ççD`,4Î!sÅ15ı§1‹°¨Ù`¬]LáNØ´5ÏiŒ›¿[Ø!*y4µÏô>šA›YrŒ…ç¬KçW5A} ¿çMB+,ÊÃúÛ£Š}YzÀ/˜˜ÍÚ¦öıÈFÉhx¢NÍm\÷Â
Lñİ®VÊÆ;}xS†òkşCğR-O_MüÄ¢¥ V1?$ÉôšÊ”—k@wøñşYl#"8#ÏüBò}ƒRÇ­Ì˜vOÑ3LûßŒ‚#«%ÔéÂÊWù»bô¸Înä"tAp· -± xÎ4ş<üÛ›*PØ÷9?'$ıOÓ}Õ/÷!”í«quÙ_’ÁÕÒ½L(ú•Ùcã0ÎPÚ„±’=R˜·Ò™E²µrâ…ß®ßë$
¿çšÈÃÚ„}?^â©]òB)k:ÛŒ¥tÈzqYî‚wH‡ßJóMHë©cDÚ _çWKk•^ì÷ÙÄÍzk=úmÁ»WææÈÀeêd"ñ"
¦±¤ÀÙŸŸ¦nW³>şß÷œÀ2d½Ë|OóR*bH}lØªÊÊêM±«WY¹B”d;_¢Ğ¨‘pÛ„«#¨tc:±¦o&'İZ‹ÏıHæµWŒ£ÙP«úC	2ˆò¢ùOô'¤×8&(Û=‚V†ÌÄHØ÷¨İ´Õ7¦HQ…«iO¸«l/äî£•„ Ie®ªQëÜÇº,‘°ÊŒßGöÒY¢|ÛĞúÁu´á‰W'îóş±¦îÌÛÓ©á9$”vêı$7hY\¼ UHßá¦‚”ìA\CÚwó•·69•æĞ2.ÕÁ¸HIÛÅ”²šÉaÑÏÛÌñÖX\ÎÀ„EÒr/¹›òàrcçe=‹¹áÔ¹Pâı€vÅ8Ğ_uVÂimò²¤+ŠbĞG·¶¢İ†İI–YÍù-¬Íjâ˜Ûô±C$j/åEó§CŞÒobõÕ°A;	l-ç2­AízŸ8Ò»C€ĞMRŒ:§F¶u%Ávı°C„ÒXí©´ğ×†Eeîzhn¢ªÁ…€Ş Í~Bïñí3fVñ.•{x©ÿ!|-¤S•Xp'ƒ1Ä½´yä¯Öp-påîŒ928Ì¥İˆï¬L;/µ@WÜQO\„ë9¬_E¬‚–´ŒoıÿÍê#Iæ	]ÊJ‹Ç¹ÒÚ¿„\}h±½D9(„Uùéu)×03>‚ó.îrÎ((å° 7çÙĞÍm)Ğí Á¡Õ(¬ê*Èİe–d‘Cä)öP÷A3ù’¨Ş™m‘ŒÕìKÍ,í]T¤<O®Q…c:&æH„–„\’L…Œ“²QSFŒ¥B}•ušlïUÏàle:Éïûó¸5C‰‰äÄÃ‹Æ \æ~Rë-éE­æwîngáú|*¦“:(øî°êÁÔ„¤¯	ß•œıÆï®¤¨¼U˜¼²Â…J×¨¾El®?(n³­roÓj¯¹4r‘Ø/3œ)m7_’VëìfİÙKß?›zÆ4‰"?‘“š¦êŠ“UmfVê< ûÀğk”·aÈ"5šñYü‡`\,6·ûqÑì<Ë%°½'Êaz2&¥ÂÚ¢ß
=tFÈ€ôÚùhc3Ç2™ ™½O”†jmöÄ½Ş…¦>zR‚rÒ"æø‚9?9ğ·+,Ë
Ø}=™ŠĞrì}&¬ƒzÙ¸ÌÁ±ÜjÈk2Œ®êzxï\ßŸº6ân„¥Ùa˜›	TàÁ~…¹»Ò!Z-nø[D%¼gSŠá¡ ©ğ“ÕjÍL”Jİîâ®,|ßbGâM7²LŒùoÂ0É¢\ŠÇgNäºu„ÿGÎ6©/º•t…0*ïáNF-œØ>Aı±Ìºr!Éx¡<”x	Y3I<-\Dj&6Ä‡û(¬Úö-k¤Ë_WHÿÉbÃiúöÃíú OqÎíªï}û”ĞyáüõèåÅSXlöÁ	;ÍdªTD&)Z:–]Ó*ÈvÒ´å¯Hf6Â´î¹³`$»Ô)¸s;­^’Û‰ÇEâ‡c;òü®äqÄÕ)õçíÈd@ñDìã.K‚f|Hb†‹Œág‡<ì:13
áĞî^™gâ[ŒY0a’ÉçL‰t]S¹§ı¾Ã@%ÍÁµòjS@Õt€Ø3,&rI9†ÛÒúšÜ•.i©-ôÖòö®ôÆ8ÄEWĞe‰]:“µeÉŠzıõ‰1õ
¨AX­H4ßD’`–âµÉ‹iÛª	÷©‰+¸P©RÏgMlõñ	™•¢…{ejÖ&
¥ƒÕ÷/9ìLÙ*i0†İ¸DÔJ¶l³ù+u‚°Xÿ5:ñ¦ßÆ–7ë`7~øu*3§Õ$†Àøó/>ì¡©°«vw†qäù+îe˜nì‚hÌPøÙ‰E'b6œŒâÅø½Õh2.æCë;cŒöÈnù`!¤ü_„‰x‹Ø4{ˆ¯±ØK45N¿LÈÇ
O
£›®Èñç‹ub	zHoUfŠ„¿¨p‚áÙU]Q/C½<3	÷“YÛ«ÆÅ’k¬(İÖ= ÀÓY-=f¶8‡W …ò ß³–y-è„(É
¥ÓR6œéZÓşÚL|Wvß®¤tw]À›H&æÜ…¡ÌëQˆ$Øs®MÌœC8»cK¢çûÎ*ŸÊRiùÏÃ›w
’s›‚ÈCù~‡ıênh[”øærÔÃ+ág.ïä™çŒ&ÙIvõN'ÏU~Ş*4
ÒW?Î/ô0+Æ¸¯Ú–ö€Yß­?Ih05'c–•v‡r„_™!ÉG^&0äüLìõt¥H0¥u"T†àËßÏó*åt‡)bÍç»‹

¤£9•ÕŠC ³Óí*¶câl@n²YúYˆºõí~Ë`SqbêNåhøÃ˜¼ŞU	®Õøµ™èæZ~ê,¦
‰Æ·ipO›Ÿ;œ¥ÿè^JjªP,I>·ÅşïÁjovoÌ
î½wWÎ”µRÑ;ÊÕà(^*âÓ’á‡Ãì“[Í¨oÔ)ÎÒ•ï7ŞØd(§²	ƒAÅŞ{À^mÕ—“nHTø–5¸e¯‹¶B+Í!ÖOúÃ±BÑ°×—@~B~¹uÈ½B"¦y=Pã[š*SSÏR;-PéaØ¼HÁ+ZÌä¤bä~ş:im¤àÿeºQ;{±ÒÆ±›	_]œcñ7m™ğ5<fVf(`Sû£x¼HŞ„\WÄôêA0?>QÍ±# šŸZQĞŞ3€Ü<Ë×xn¾>°KLYÃ÷t‰KKhXf…cV<Q˜(e>Ğw1U.z6_G@†!”ÙüÚ­n/É§sñKÌõ—3şº(F`3ö*©Î¥Lƒ14ú‘ğ0¨OûÇyÊ<qŸy‹¼U!§’uP1÷~WÒ)®K}LoauøøÃ<k(b„7ubÄOóBX¼“(ËàÕIâì:rùŞé;\Òtœ;A!/¯Çf›©Àû hªbùÅÍ€ËÔ,õŠ8Z2d07ğQ÷æÉ!Ñ{ØºŞ:!éÛk°£ EËĞçß1I3à£¬Íœ9¿Ñ&ªaè¯³ÈwVUY Ãl›r‚¥5‡Ã6Ï¡40ƒ.â“ú^<ŸcU&ñÏw‘„”`ÑªyØXã%‡Ãf«rMD ÖµRxîèßë½|ˆÊeõNçq“¤(·K†MÆNĞÃ#Ş“ ò¶i$Ü /=¹Be÷VOÿbx¼ûZsÕ±é.…]¾ŒXØ%æ°ék1…„#üùnƒüß¡¬ŠÅLëã¹³Ù…£Äû?²Y%äPôÙÿcú ¥%½"Ş¨“ædkcç\üôAUÅ7Ç€Ã]ŞèdDÔÅÇønuRlÉ`ÂöŒa>$©Y=CSØş’!”?¸ÈªXÑºæ1 Dè£ª@} ‹›ïu?¢8]oç•‚wNÏßszùœd§éˆ˜ûKGØ‡ç2tô¿wQ¼‡ƒÈÜNÃø.@E;Ğ…ğne¸&œ((Æ¹BÜ;ù–Æ4Dô®8ñe®.€Ä3qîE¶Ùõ`µ †šFfÇoÁ»k0B;x¼Şfæ
~w ´õr,ŞUAaepD‘½ÉæwÊÃnhv´kğc¼xÈÿjŸG9¡ÏÏ/Ï&Å&Xâ¼ºÏ«ã['Ü‚—-£Ùª—z”z¥J8ynkÊ?˜OHşæS	æ<OÓ™d¼ b@Lñjñ`\®€Dd,6Â3´¡\"ø[š#êa¨KÂw,#¡Õó¨Š’n—ÀÕ.™XUaì8|é‹ÓåÓ#–«‚4)øĞpXÿ©Ï¿â€KIŞ)OÏ«×]›DiŞ
óÌ~ı¡"H< à–B]´ú}ÔG°ÚÎ/¼9Õ8§Ïe1T®8+ğ6ö˜ë`[o’‘"økWÖúŒŞŠ7²rÖ"vùoñíÅ„,A=äHMğBğÍ/z)Š@ÏrD^¹æ}ÑººTÆp”:qOä±zäí´LGÑv’ã*…“”$¨_Âx59¬?”ªHšxÑj SˆµwçüÕÇêe<Ù™³£’„}†äÜg€ú­Q•Ğ(x?óˆi‘”­@ €ÚµGu"M¡—xOºOŠ  Ÿ¹$.5Ò[Ùï¯qšùŸ¸È¼¦¸]ÿ¬"C~ş•úµrÄ^E\ İË!³]‰a<<Å¾à%ÜíÃnt¤|uâs ı†CâAÒCaÿõf¸±7Öä¦Å©ôNg‰ÉícäØËq)M=ášÈ™ïÌ¡g´Ğ­K¤îµv‰˜\˜Fë×tÀø´Ó
ãñR/NÒC7¹º§<ÍóíÄª‡BÙ4¾óÑ•ã£FçœÀ^uB{bÌÄÛ)ÅéÅ#~2„X?3d¯ß’†Ò:“*yš*<vûñ[Æİ 'OÅxúšƒT»PÃıæØöjrÆB_„”óÏ÷ Y:ò·¤<ZAÜ4VLS¬:Bàb°R·ŞïÂ¨RÀ2Fj“³lW–ß¢Ö:“^ás¤Ï"Š
îL+©0‚zßĞCøfš–Í]AãE™Ç>4õÉ¨rØ|¿-È;˜Ÿ¹ü´¡êîp×³ü÷½šÄ·ØQşVê«]Núnˆş;ié©½ñ}ì˜jb´â2ÿºk4àÛKæDJÑn,Œa9ÅÖÉjš76nB­¯vLáËŞ§¾Ş8”‡fé9[‘"÷,¦åjûmè»i”PÏ*!²¹ñ÷P¯óÂæƒ•—è«ŒÈ•‘7ZÄkããÖG»Mñ§²ó2ÒÕÆ}.YU]Áw³NÔ¢rêê¤b‹ ù·BK*1«”&‰~õÃxw0¡MiaåÉà† ºrÕS=®z|@h‰ìvï,Û04c+¨wM­éÆªWpÆğdÍ…àš+a@ä=­@(TòS‡­Ğ÷Q~>µäK:L<Şs;±+’Ú'ÇÔgûøÍ;¾(zHY}ìgƒášœ'Á5dà¤âÃæiœ|=W\TkÚ¥VòhÅ(æc•ÿ²µJ}AzğCÙV¶3·Ÿc¿evMáãY³<íˆ,Šs¹ h–ê6á"Ò$o~…{—Ê€òÈ·íƒ§TÓ¬?09jGa;wüïe¡QHŒHç·p)YËñ«¥WEé>8ƒğ %õ¯D#ÉS‹o¡»E`Î0ŞE˜òºNğ. ß÷Å{	ß(—††íš4ç†ãVjûæ±SO»vª\›iz¸¶¨*D3[¹ı¼„¢¦5íKÎPŠïñ+š<jıNx;º¹F®ÕuªÑnçMf¥
¡ õŸ£÷º«3vûr·×İCyMj$Uìšç¡å„rè×o5I^¯U$ #ÑíG€ÈÓwá¦ïMÇÛXÕÂ[°[uNdz›Á¾5‘K~³Xæu	_äWùQÙËwÍªw¹DÙÌ›ĞB¾²l‘œ8M­ü¨½Y(¶Útm%1v¾ªÚäF	ÌŒØ·}oéZFGĞDGt»ÕN<“Š÷¾SşmØv‚K	Â§b!™fÔ°È<R#*nz‚•­Ã#$®ÔÏSï~j	ô÷8QF,'^Ã¹‘à`e’Œ{¾ÔÚêŠp}§Ï¶$Ù…­_çâú²nÓÏËıêV"aQqjÕÅW^‚×"ê°%RUª±2>µ8Ôqš8m82O¢=Ån°új]Ûÿ¹B6W™v‘57Ö"[¢İÉ1[á?(…=G!àB|ÖyèÁ<©ÖE±ætÇĞti†öWÌ™Y‰|)7±ÿ28¼ò°}ƒâEVùµR?Ö-7”¤Y¢Î“ÃéÒ”ä‚R?\ƒ
-Ä		7‘%'8©E·UYOx¹|AS3Æ3m—‡Í?]´Ë2çÓ+†vùŠÌü4ÊÍóƒ-*W&uqn@Ê$œ/ ¹Ììu¬¼	->¹¾0fä¦4XY‰åæß%X–+h?1›z(bv8’~Ä—ùÀ¾ÙÅ‹b&+f‹ÈîOL¨2óMÈ5’}:é¥ÜX§ÀÔ>ŞZ«Ûê;ı|y@†<n;ErzÚ'ce½–°U¤ïC­Q„ĞÚ¨üş­[<.c®†'FäÂq_ÖÔ®¡}ó06ĞH.É›èZß)õ|¿Çë—ù¾[ç:j²94"Ûy¼_Ùoã… Ó=R±j®áD3ß+ÂŠ ÄÛÖuZ=(Ë»¤É Cd^¦•RjF»µ¦:+/Zïí}!Èc«X©Y[ÆIrûôvJ¨“åvMÕzsXo>|M)a¸îv¥>dÆ½óKqUºhÂçSiå‰‰ÓOF«À$Å8ğÇ(‰]v0bä®Ñ¬Ó¬‹ÇÜâƒ±¼g±ßX/M_c/yR@ğ\ßAoê†Ğ>ëŒ87j,"Œ<–0NĞ‘n“öç Œ²8ßA.šèŠrqÂ„ctLœ€î²B®Ì°'JÃ+9“>şÛTTp…¼îòÛÃ²¥iZ1œÎ%6ˆˆ‘€™7^­&ÎçÛbùÏ4Úô¨¡sêÿ*v§A@:T§lLH”üÇ<T`]!MÖèëğ´ˆWH¶g»µCææ‘ i»!
}2çü,ç½H£[\:qP×ªèË‘<ŸFbÚú÷f6İhCF2nÆ’33+ÆKm‹O$Å9EÍßàÆí™—/V9ëóë‡Šü‡0j<äálz`vE'…õcVÓw$é¹í'½œâ&°\½£<€ş…°lOvñzì" ûÀâ¾#:ÖÅ,»5ô9+H">lø¿Ÿæ,ØZ”dsj]ÁÂ¯H³]¶Mõˆ“RW<'?ï;b)æîKğÇÑ M'i]çĞ¿³Ñ*¯°=jŸ:–¬ÆRîXª_èÌ'n{­Ú‰q¡]ûïOı·Áã'óJÁL~ÈÚûú5£¯¬ÁÇ\¯Bzç«ÄP›+v{ÚLT¾Õçî‡ó¹ø¡çe÷ƒ¶„§şaEÆ«aö¨(ğPıŠSí‘Zñ2²,ómòx€Jä¶EQ…÷å)Ù=/œJ3Ë©ÀQdŒ×Ømöâx ò†t<ˆæÅÂÇõgâ@ÒÖâ	F3Dä?r•4Xbt^9é«ŒÒv×;ãÖN¤¹$Ôû‘hé_ß°m-Q½:Ò«h¼õ¼»?Ÿ0ğv„–è’í˜(ç";¤Ü©¤öÿa?U@ŸÁr´(o6ò%œ~DxïdTš4Ó”’äzM%ƒ»|àÇÜîğŸÇQÌ\hYèÓÄê%Œ›Çµ“D#ÎØÛ\©)“½%œR¹ƒ¶õÖ2•Öœ`˜”ş Å ±şâÆ;‚ïz€e>8èÎÑÀCk(~TæèT‚\øV9¬ç/ÃZv•ªI„¹@Vû4sÔRÔ>´zåĞµ´pjWåé^7ŠWšŸ³·¯m¦³íÂäà%û­:®,¾A™¶ı".Ø~}ôšiçtVçGıC7Ù5ÖÄ¡æS„š¯Õ£t¬b÷e± N@Hl ÿİ³ÄŸúam½2ÿ„²ŸÄªÂ
2¨õáGh`\‘7úL)Õh=êhHuµnYkè®rÚÉœš 0[Û6\6Ç¬‰0ˆq´¥8&®Â¡d08,BöĞ³¯…Ìwi0@DÈm¦zš¶®SÚC±ÉL@çAõYZÍå‡fÁB&iËR/™óÒP¬ç|?2Æe£Câ’zÎšñ‹¸o* d<›.Mï]Ü=NÎ¦’cÂ7@ê–1…i‚İÎá±Œ³ÒÜmëp)Jì1zÅÇ,xÛVö–—›(Ø2OšëªToË++N¢ùZlÈÍ¯ñ…¯¢J¬-k¹µİ²êÆ‡D×N—÷ˆÙ&Åş>£ĞòW<%»O¨½İ~œï DZö6£Æ ¶8ş…µz ²¤k&È©Ä$}Q¦YÚoó N¢ïà%»şA?‘›uş;49~"r4ëSüõM™è¸·‹Ó|&ØêÛ­LşÕ(‘»„@CkCºÑjnË,Aê`TÇŒ/_Ó$bsß½_9RÓš*åû¯ Ö›–ßLÁ7â´%¢Zëc9 ş¹^	O¯—â?ß¼´Ëöø(xÍy\Á³x\ûBp~ôE¶!ØŒ;¨~?ş`Âì¦'Ú_uÄTgÙÍˆ\<¿øÎ]XJ~PVæ2ù¿¹X> e
ÔıÆ½¶Ò˜¢&.>Ns‰í…jÊA÷Íän#*€TZte§Kç53ŠÚ©Ò«Å²½S’YÌ6ÑwÀUşuGÅªKB8]M¦âÆèQ£8‡9ğè-éd/~HŠYŒkénv“@5‚¨ÖV„æªAº¿1/›®{ß)@ä±<İ†ö£˜¾ÁŒ!ûmQén õ«;ö±£‘|[„k\@ˆ¥Ğ/?AÛ"Øw.¬Oªşúc2'‡ùLßÃÍ§ó&5¹ÍhÄ)Ín´óşïM«`İá˜n}¼bj¢\ŒËKäôofâ^»5Â-EÅë‡Qh×š¨“8f•¶n-aKÅSê`54É€m5¾¤%J×RâçèZ`½~tU¸×¼ŒÚFú+1Ä<
>şÄNbƒ%HêLT*¶dØë¶”ˆñ’ßùôÓÏ˜‡õ"—m›y„éÒ‡92^b˜~ÍúOË,x©ç…‰ÎÀ5 K«ähIş!®…HÚxP­š[+Œ0y…çkzk Åı8Ñ™M°‚)/Àš£
/	BÀG]ô«8Ö–êWO·×Tÿ `€o{›FIÉ|€,ëR„•^ï-ı*Èn\•HÈ÷-hŸG™¥ÚèN,rÀìœšG¾K¤wmĞKÛB¼H> CÅwó@».çH*‹êş¨ğé¶jÆß¢¯Š	,´Íx\ç?¶n$T$[^â“eš	ÄœjÄj…rËQV…ÿûRAˆ"VY‹ûœ®h™¦Ú„c‹©!c"Hg=œõy
N(¤UrdS1­.½•j%Ä¯6ˆÇ xáĞó°&S˜¾md!°VßM™b'Ğ_ÆTyàØšÀØßpâ6Éº_8¸Nû¦<ßóÕOTšLvIä(F“	^\/SÆ+Ğ{’çFÌ“\<5ãnë®šÁºAs”jIllV8R…†:Š÷ˆÓ
ß¶B¼ÎII£1<ÆÄ¸Ó÷Î"PP/¶A%±â}½ F¥aYm öËu¾"¬ó{”A\‘@ —ãäJé¦Å.íİy~‘’}ø&‹ûA)a°U\NOñAsËÇOàÜdô°û¿D-gøÀ¯P3[?¦¨ê×Èë:‰Èß¹¶1cÏæW#ôtß~+h(‡,Ãûs®©ü-yn|¹Äl™Käd5R7Ú´dÄÒ<ë‘í W–÷Kø®†HËv,vp„?^j<ºÎo³lé|!íğ–ÅÓIÖ„‰=ÂEÅ2Ó
³m*£Öá—¿×ôf¡IÒ¨ú~¥_…ÇüUîxÄ˜iZ‡µpÚCã’jK,\¸Â"« ´b'ÀÃ/YRÛxì…¾êÍ LÜ\áÑŒ$DğwLâámTj«QÕÁ1f”2ÏÕk0‘’9N½„gF”.Qí“Åº†la$èü7ÕL±Û¬\kä.(¯Ywğ×fù?µRÍe[
Òh‘e’kùj\2¿EJdª½5,%Ÿ#Ç?ÖJ‰m#ÙƒZ‚:Œã0Â¶®$af¡+yÃŠª‰íTk³E¶ŒômîúŠ×v
xĞ]UÉa
¤ó×¶¹@t™5±½kM<€àß‡Ë›Ä¶í°zbª6ìL.éíéÃ4°ràuuºxqçŠ_"à3—kü ]¯Ï¼ÿ ¬Æ€°	ÊrN±Ägû    YZ
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
�7zXZ  �ִF !   t/��W�c] �}��1Dd]����P�t�E	��'�O�0�2[�TV(��_�R�%O��Gx��N�����8d�r�4:�!:�x;��X�rU3��'� %��U���܃�;�	���������%@�c�h58�^A�;,E�����9��w���W���5��>.�B���p?���(k�pW_g�û��dޜ!���J�#\��*3y��`����pTWd����.��S�CKF(�y�o�!��>-K�=��,tΡ�m�r���7�I�{�T/��䔃�����NV}u��C7oЬ�(�ߐ[)��[ڗ0QF��������>,l��@+�'8 )�'g7�o4�I�nx5�8���_|��%S�=���fE�Uw�s,wb+������9�+������<N4m��e�2I���z�߆?�!����>a.�G�TPԵ��х�,�Qo8���5���o�m�KX���2�ԉ;�-���:��ʨ�[U�G��4@<��`~�@��U��K��ϫ8"!����'����҂d��8�rh���B���Ɋ`IcjWﳐ��G��ԋ��_/�k_7t_
GKW��F{Q/P|>9^b�R���0 f,��Ap�1S�48�I�Y�t�v(�&�����$�px��(�b����rH
/��H���ˢ�cyL�taeY]sl���p�hF�j����3���3ꅋ�G�Ā���g�)�}a �ŧ9��$��8����!,��9,�NryS��[@'�Ӛ5�����B	�dp��.��3j�������f��|k��n|�$pP��^ej~����v\��t��7</��
����Ȣ��[����݊�:�n P��a0U6@?�-�1M���N�6�E��A��,IU�F�U��O�M�/��]�� �G!	@B`s�[E�ƃ�Y�+���	�ތ�M{��PԊN_��GJ�����@7|و_>+ԪS�cj��z[��I�4�5�H���\`�D��L��*��Ob��Ԁ�uZ�[����b\D�g�tr1C�Oe\��oI�$�qJ�maeG�m~�B��j����2u�&sm�]4X#?�p��2m�
X]�-�ӳ�^rȑ�sb���!.�Tō�/ڭ�R69c,<ƾ����(��١��ا�-L��/����fD.Ҫ�t��X�-x�-��1���]�))��<P��[� �,�n��
�\����k,�� !2�a����!���F��t���ݴa�a����綪ܒc�Nu�Ǆ���qQ�y~��5��M���g�v~�I}h���I���3�J�L� ��ۜO��*k`��ɂ�w�%�����n������+�8�f$v��O���U,~O��S��#�g(�'��]�xn&��k��z�g����ی�z5���y�1�Utb'D�L߱^q	��`;|�|�������Rw����G�S���d�s�a��"�"���0C�J��.ӛ��bؙKV�̯����D.$�;�Fz@��T��t�H��w�`K�	.-W,��=AY����O���>��۹BP^9���������R�&	/ ���N�5y~�Ñ�!;�\�ߩ�,�0ܨӡ���L�O�u�*������Vkl!�,��:�����w٦�����X���T����M�!M�>a�ᥕ=e�Sծh�,��z&{(0�����ǣ��~�- 	
]8/fA�SE��W�ZUw;��k�`���82�3��珆FLT�bG�7����q��-/4{� ҟ���:-��S���(K��Ȇlʾ�b�%�;��'�+K��&�M;c����V���)&�������>���C��<�
��!�� ���ji0T����d~�J�|��R���^����	�޼�^(m��β�`�W�<O4&h�x $J 7qA �fxl�8"z��+c��˖:��F�}	�mל�SCyL���l���9ņm����mDO^�h2[�#{s:��cK;��|�.��xǌ��l:��6�A�=]��Kl���g�nw��B;�F^���9��
�u@�q�ɧ��|#�­^W���嚜���&='D�,�Ϥ�7�`���a���_=Vw~f�9��3 �G�p�h�t� K24#�~5�I�xd/��/��?&P��k��/yѾ�ˠ��]��հ�
��5(1��s�B݆�+nX���JW�.y��b=����i��%��0a�<��xW+6�^���q�
iYZ�f=s>�q��-Hą�����g�.M��t^�V�!W�C�mz��~Rmő�K��Q�vW�D[e��y�5�FZb�Qİ �Bb�4��ϴ'�W|�����ITPO�[~�k���ل� �Y�&��9��NT 4���ABG�Դ ��t��a�ӳ4��ğۆ��[�|7.'�Ww��*��J�I��V���,Ò�|M�}��:��:sίgU����s��*f�r@�y�cAl�6��Y�g�)4��]V-�?ثio׮���_�hS���l�A
�<�X�j��E� W���s>Ǌ��ks�N���2�5]	��E4 �MEW��?@����L,�j�Z��XtD��Cv���{&4�l�_�=����
�6�LNr�]�/���zn�K}��F Li�)�-������\��0���1��C�J���O�����:�V㧐?�5<!�1φ�#�z8U�m�;郔������!�՘Jw�C�7��v�j���g���p�}��Y�2��Q(�='2YJ:�f9c���cJ�^eA?���H���u�?=�6B>s�N#��(�*XA��������=��ꛯ�T�Y���y�t�G�x�^Aɶ�Z�bH\�z%�*�v8��=�w{�i�~U����{��
��0�r�a�o�]�|%�k��4MJ���ȉ^դA�0G8|���ttcO\�(R���pHk�Aχ�'9��g�g�I2;�e5�C�O�=A����+�Ns�Z�����L�9O�ut�_8/I���:B _Qf���C����$-���,&�&.�?&�"���ŋ�3]���I#�ţ��]��`	Y%��{����т�z^��&J^3���c�c)��;R��fn����=Ayn���(3����)ugt�����^��J�<���uC�0���f&�}.��Y$4��p��34���%� � [�C��`�?
Y#��h��x��*_��A���L�o���5d@H��j��%�܈�R��H�t^���f�:����Zk�I/dՕD�[ߕ �fd>7���#h�QV�QT>!�S^=���du$�I���ջ�#M���1��U�"2��xa�`���"�Ϫ��+}�u$�YF���j<F�u�s�.�7��̻
j&��4sn:D8x��^|��?�P�C��n�.@��}E=�HC}�W}>1pce�FG�>��|*"��'Ey?6���L��6�5���#уz��yP`�_ �Bۖg�{�^Gt7k��@Z��q�a��;�U Xj��H���K8�	]xMj�	g]~�i%0���!m��Gr����	2}�`���f����,�~UrK6�H(���1�AO����B��/����``q3 ��]�!Qƾ����`�l�V���T�ej2rW��`r��ǦVl��Z�*��,Ƃ�3����u�G��QO@����$K�:�h�V�-�7:�cCF�~~����B��1�i��������i1t�c�T+7 ��>��0R.c�h%���-�^��p��$ˇ�H0�K6Ӱ�y���B|���X6��,�E�~���u�B������#���+��&~~�ﶳ�Z�D���- J����ձ��Q�������J$�p�Zz��])X��G�V�v��S��r�3/]fzFt�&E^�%2Ų����j�����wJ�8�B��I�������9��:gs�x'&��5�J:����x��R;%X�ҝ���5`���(��TZ�0{�2�ic\�M���S� 
n�f=����bO O�cN���=5#�>#�%�߳h'����t�h��W�wL��mV��U��z�&����j}���N�hw����e�H��bh��sq�)��F�C�N���p�Y�\x���+��|a��R�������LH92��J�c{=�r΀ܐ�#p=�������!;��X,'��&�	��<G�`�y��A2���[,�h3!	:C�FW�'�ש3F��5i��j��[ōWл"(",CX�ZDlt�]�%�g���vM㤞��"������T��s��[�3|I�j!�QlsgbYV�k4���*Fa>I\���X����<�$6M�������Aq�lNP�3�U��n��6f�\v�����_LA�%����}������E�{D�[n�-�C���z�N,$@����A=����z��B3(�t��S9�<<�I�� �)�3������'� �{|]���Kn�AF�U�+M=�L1g�.�`��N
�.,�;-b�'�gW�{��s��h��}��1��4=�}��00G��1=�a���,��'�Р���ܛ�[��X<U=�+��tN�!Fۍ�a���r�ccCWD%��*�NJI}����pK�8S9���W�%ġ��M��L?��,�LӜ��B3��^���b4�ðb+x6R��!t��x�6Zƴ�zi=�W�;2{C�u��}��LJ�qE
SԻi����H�׸]�`ʩk5ȶ��V���1}�z��+s�b*���sɠ��Dmj$��"T�m�j�C�v�h��H��`��$1�,t^����A
=�t!-����C�i1DQ� ?+�n��,�v�*�U��AF�RXݼ� �jl�/�!7��_X(=��w�C�P�0����D
�K�_��E����Nx�Z+����X�4KV��l�M�Ӂ�'���Sp9�m���藁��_�4����n�V�H�pa'�Q�cd�ki�WQS��Iز�e]h�K]>���Wn��W�b�X}����WP����k39xȴ�E���%��g7�~�߄(�C��]�\�⨤�.���ܙ��!Zr08��2ƄD�i%\�X�Z�lr��e���*�a��3.�"�/�O����\��R�2��`?V���E��	�U9GȒ�MS�����k��F��v`;�������iԅ����w�V�� ps�N Pm��8C�W��'�w�*P{V
�.��:E������ŨO���r�~'��J����{Рom�R&R�
▢>���tAl�QaӢO��0�8���
f�#�k��_:/(�!5R
0���A#��R]^
�F\�UG��6��n�z4�;�6w2�*�+���&	disw�	�zrcw{�EM�n�A�_ W�SYtO���{+����$HC0Y�^-n�[Ph͉������]��@~4�5^�K C���#�?dϬY���rA+�"Jb�4j�tr󓮚�e@�"�Fp[+UXU�O֠�hACg�YC�D�p<�����6
�
�`��q����⫷����3x^8�Y�(�н%�LU�S�5jF�e�X�}�WV ��ӌ����&�����S`
#�2�,�6���-���0��3Ay&U6���u�p4���Ne�$M!��C%�j�E�&R�t�"^��Q"�JQ��uL��?]��(w��H F�e�Ȓ�.����0�
'���M&�":�4���{�����b^�bEw.�݊ҏ��3�΅1;G\�U��2��5�2��7Q��+<E�I�U{'AT�a�U�������ǂ�m�u�/6�j������D�"�t�Ä����l��C�X�R�(�kՠ>�� ����#>�r�NH7=�WR��@u����-, �f�l�	�~E��_���~��؍}:r����6�]����9]�a؜k8$�"" ��gp��A��*�'	�����ĭ��}{A��l�.�Kq�㿌�,w����r������6��ݨ�i������¶w	���]X��9ǋ�ۆM�H��2�]�XВV��y�0�j��Z�\���kC��� i/#%��	W*����aZ�����!����J�����[��e���Î�. �����*Q�3����D�qzU�̙��Q��J�}?�[o�q�:P�����첨8__��ęM����T���{�/3����>s�9���U,�t���ßgw+-�ێ��Ɂb��t��7 �+^"ݳt6�������{{�V{��ȩ>+�#R���܎���%;�t�G�?M��H,���ٶNkC�-�������Ěą ��V��{�D'�T�^���GykQ���o/�(H�`��Bk�)0�C�y��Z�I����`O����9��F�vF���3�X���9�Gh�;F8���eIL�d5��.�Y����9��%0�3���MSg��λ�qw�c��E�(�Aa�����n���%�O��s����C���gjQ�\���0M���2^n�}��kɥB_�$	H����b�����^�ť�S9�)��u$�s6��]��1�3B��F�ڕ�e	�9�.¯�f�d�#+'�}v}3�G����C���$�B�� ��aw2��'��f8�V�����W@茲�'5�8�e��]��o^'<�)S��e����#�ܨ����Nk?M���t:9��6�_�4�I=mO>0��%&!V�sK��� ��&�G"���$�	�/|�|��y4�p\���飷22M��L@m���mֹ
d(7��Zǰ�3":�u��81�h�
��a�g��r��%\�IrABN�#�q8_EK��Oh0y���F�TP�m�|���gBP(�fS��}�z�˰5#�}�x�OȩK���v��(La����;�C�R�
7`0����8������	�DDj�u��M'�u�y�Ӭ}������Վid���Z��5R�����amE������ʽ���( �nBX)��1���҂��Fآ��њ�����=�)�<f3RcE�V	���	}��fx�y� ��(�د��WJح�Xx!�:_���na/C�g��|?4o>+�����$��a��H`"l�<vy�}E�7�3�h*擱�ǚ1��,�A�Gի.��/�@N�"݈���k𮮐!�u�� "�@�
Ug����,�>p@�^��6J��?�����Md��w��M�t�z߂D�?��\���%%�$�Q �O����9���l��}��f�m�vG�ni(7�^t��t�\��܁&���gԕ^/rP_�a���_	5�;=a�6dt���ˇ������U5�9#�xZeZ5�A�B=���u���g�'_�8*���4;�������Q�N-�Ok��_���I��:@�;�[j�%��1��_�Eg�F���gٌ�r�#�����'���(FZY����#��ν�:��w��m�7�D�d]A�����Jކ����D���SC�A���(���)4$Û}^H�S�B,
�{�s�v�1�S�N��]H�Df,��uc�Z�3>�4Άq5��f�T�ܛ|����H�jP��
��Q�'{u	��5�b,�k��AS�-�ъ�x:�íy)��}ʬ4QuD�Eӛv��v�U��E�3�چ�����d�h����Q���/��"Wjd1"8$�Ef�j8��l�	\Jޔ�r�9t�,�[��+�M߰OĢ;��H�ܻ�l۠��x\�8����]
[� ��^��n�_��C���7��.�0�-& �a�_�������O��"�MNIn-|a���y��_t(�U��qKiCks�9]O��ۃ5¿&�ٷw�~��U�G.Wh�3��8�@j $��9�CH�Q���'�t�N��,=$�4�yԡt���H�q����L㱍M���Ѥ�͙�R���Q>�6kp�j��浤�M5�a��ɉ:�I�u��.�h�b��C�p*/�?����2(���-C���]0���F��F��05�}�m, ���<J0���B6�;���J#_�F��
\h~�b^!����s���b7��oo^͸�dm,W8����o=Ѝ*��ʢ��?>=���VBB�BV�[����>ߦ���[~��]��P�R9~���rO	��X�ZUG��	��� �L{���5�RE��Fg�:��j*�	j��#��jH�_\ެ�4��;
�j�~�l?d*�hnlF�K}�z��F�����r gz_(v���.�T�o���1i�+AJ,B��^���,�k��	0���JL�JE��=���k��ɅT1�Bv�^g���']Pd�N��HެQ��f3�=�����;Q\���?"�T���G����7b�	��J���wd��8��v6e"��R�W��ߗ���%�u�dX7�2PK�^���1+�#�z���i�� ��,_�$�������x���$�-�$Ew�*6�ٱ��7���15��2#6�����<��XhpN�Q�K���\�.��)���0mc1������rMy���E���η�	]����N���d�-n����˷�ɿu����%j�Xy��{�F�)H�J!|�%:+0}���V��pS'�.�.C��J�:���g'���G�~]���I9q�N����b[>�|ӥ�#k�R���)�L�y�� 5��`{�\ؠ��|��ґ*m���^?�Z����G�����(2y÷��x��>5ט]�'��bO���O3�O0%4+�VZ��Ҝ��1��w�t�@�3;ʴ<��T��\F��^���俏"=��A25$�e�%��z�r�vUba�_��y�:�������a]�YD8��7��r��^L�e(n�/nеB�<W}]�Z\P�p��Ԣ�%z.�RɭM���[>8�����-�eO�����+ɹ����-�)	:����|;{W����V�N6�/�����3�bō���&}e��Q	Z�q����*dg�6�T�m�1�|R s��R���3,������<cfY'7C7G�k��&�r�=)ݦs Nّ�]�j���r�A��9]�-Y�6��8����<n�!/���޴s��/�-1�GÏnм��Ӱ�rT���Q�0�N��Y�xH�q��zB�E�Z-��b�V B
�d�|�&���S�Ч���cf�K)���=-��"@�]E��C/��*��m�{0}=��e�Sд����C��s��́�_w�(N�O�	��io��>����:�|�'P�_�`Q��:�F�)@w��1��.#�j�	c�#��8�:�Ҭ��[�q��}.�˾SU�B]է����$3�}Y�����.>6�Ʊp|����y�w	Uwq|�a�L� �z����* m�Pպ?Mm�y�t�c]v�d�l�	�Xr�S.��r6h1]%NX����M"h���N�A�ME�@xQ���h��ao{2�ZД)q�c�X��R�>�����X���Y�����!��0:�VE����{?i@��w�b��|B�(E'�ٰ�8�Y�Hx/�� )��� �	��X���Ľ�}4Ǡ�PcfK3a2���)���}�B��&�
���At�wLj:m���,Q̏g��b18!�s�=��'��\���+N�QE瑥��P<���N�N.`��.�o�Yk̗�� �T���F��&�-ent[��������Ǻ��l�Y%��l���)�k�`Yf�����OR_�u(��@�}���*r�ᙩBoX���ɂ���+N��&N]g�r|��:=�<	JTncp �M��/��f�#z�kp��MB�@H#R�P8�>�|>caK[k�8w7����pW$��3W_AYt�os�?H,�s���'�9؝������D,��?`?B$0���p+]������;+�j�B�"O�o;�
�لs���r�\��i�(���Ȳ��v��2D�`S�3P�i.��n����Ex"m��'��Y%$����z%����,>�1^��)���œuD_;�Qv}�9��#�?��_��0=�\�#��� �2�ݞ���@l&2V��ð�Nx/��utf���=D�謢�Y�P�h�m����m��U)�E&Vd�8�+�{#�},�B�1#�d?|�2���P�Y
�ї! E�j�: ���Q��X��s�_����U&cbE�]E�SD��]QZ�?�wƛ,x)u�Gw�e"%�1��a�<�ｮ�Ln,H��5�z51͗���V���=P^CÖ��t��ę/'�(*_�Yo��P.dВ�Q�û3��xcIE($�����v\-K�=�w�-���u���������W��Wu�n�@�;�z~4��x�u���I�!\W��Q��?��g6Gc�	}@8w!���<����;r+R<���r\SP�!��,�(Iz��e�E6�����q81�������,�U������NaY,9����I&&	�9z�^���	I�����,A�kr��;[���Y��6��v���魺�z(@� s��:AHs�E�ď�[���!T�vҢv��eL��B���w�!G��}޺��|�lsE��*r�7N��0Y]Q ݟ*��B�g��-�[�jx1��~dv���(l+z����Iip�!�柚Ǵ��#_̭ ���1��c"�&�c1CG{)(d�Y�pS��WI �2�~�����ih)&!�ϕ�H](�eɝ��_[�D��|SUv��<N�M��f�Z��mI�73�Թ��A�y�HO�:Ꚋ�P_UKo����\,!�JA����R����$ßN畎����gC`�k��YXmM�Z@gxE�p���}Ͼ���otU-�*�_PcG/�c��TO�
$�Qjq\�A� n'_�k�K�.`��P��n�(��bxߚ0��W.PlO��'	�Jj ���߬��%�%_��>�$�KJb��s���DT�"�@�s���@�Ѥ,�8���ms����/�E�s�<�*����UR�z��Y�N?�Ǵ�E_�,���abE��~�>�úi�9nu���u�汜�^l��((I����i6�72��W�t��� ����N�J��P��-�����-�{e�?��U� uם"�~�l�Ԋ���0ʘ&�v����Y�H0��9��K�Y�9����F�Jr8S��%��ʃ���r��l��9a�2�	�٤H��c�z�i1�9zKK�O�M�K)ȄU��1�3��eO;�����v�JB��+�����_!;����uܘ0ǁ~���������ה.�a�[�
QL:
�ܰ�r�I�C�����8Z�,��k���{`��fM�_�(��&qm�|���x͚�CT�$>�	3�k9Q��ۧ7��3hF����h�2y6&i!Y�7���z�3wc�F���Y�R��Q��WVy����c^ }��L��iՕ�H�'I{���C�JC�׌�J��g���S���k�Vf�8y4�03��ʰN�=�"�..c�������n�ڷO1��g�R�ڎ��E7_�VL��D&��-D9(xڍz������>�~���GQ�|�avr��1I27ҵQHl���Ct\�I�_�����-�(R���HXU��f��FϸT[� ��]RV�6�9�j��RF��ܸ��	�Ű%���p�Ag>�"Qv�Z��cɦ7��8��ƛ���e�'(���Ey�M�Ua+=�+c����1ףqRD]��L�7_B��B��7�L^�i�P�-hG���4��V
t���$ۈ�Ԡ~�5�]:e<�0)�p��l�?���' ��]��2�Vg��yG	���.LI�y��_`�?��J��x�Nn�A)ϹH��*'bA�>3��D"BP�C��<T��OdY�l҃�"�_n̏�Z�$�k��~EM��x�j���M�u����S�M }�0�ٟ�F5�f�Uy�!�҅�X3u��h�qi�ֆ��
�,UY)*���-�YMO�N?:�������ы�,=CƠ�-��I�Rd��-�S�I+߹Gh���5�

��4|o���IK6��E3��`ܱ64S���2�MHJ�ԏVJ�y+����ׁ��L�9���4��s�S��~J�sYo�u	��Obē�\��k��[��&5B�E\�`�E�C���x�`C�w�`fn�<І��ɻ,k���'J=0]��Hh�
��k�j<K�о�Cbz2��-6ly_(�a��m�,ь�՘��Y|�Xc��n�O��C���%y�-��}��$	��>��ǔ��S��h�o6~��N�b�84M��`�C�&6��'�@��-��3E��r��Ƅ�1:/����30ܦ����yG�H�����������M���O��R��2E�j��6n*��~
%V��)�/�l�1��x_��Jܠ|�&�9t"�
$8���0��V)Q���I{Wv��>S��%������E&��f��VI����ye<�$��2V�������2ߺ�����,w�ނ MS�����)y��l�6��Q��~_�ݔ��&�M��w:����QQ�qD$_���*�V���9O8׻�97VR�����G�m7���?ȑ̔m��}t4�|���.��5>rvꁅ�=E���v�hrA�����Ir�?3�1V	o�X� �2_a�I�<_�Φ�̳a�����Ṫ@a���#��X�ѽ��z��5EB��6eJi�����ݒ B2ݗW��?����ߟ4m�$�т��m��_�/1��;#0h���c�+��#ʹ��|�d	�T�X�2>�;n%A�6^@��^؎q�1����n�κ��O��]�bD-%H4��X���)H��f�nI㑣�#M�P��X��sҾ
D>��Ʀ�6�OM��5'����jH�un-�o�q���]��	�e�{E�O�����j�����}މ�RJdSu.��f�"��j�K
��fK� ��f�X�6Un���A�Ǵ+�'�ϙ�9C,�s`�.b��3<P��.��F�Z�t��?�a�5r���&:���]���t'�啨�3ܙ)QF^zGٟ8���n�[����C���g�b�r6c��X�;#���a��Z���!��P,���m�=�r*�l� ����(v=t噼���W�������
0�"�R���y*ODJR=��/�SB�u�j|�=�ӆW�{XJg���R���_�l��ߛ�ܙS'#y�����r�]��#ͧd��ϯ*�D%���~񾑔AƆ0�����Y������%�x���U���l����q��]Ύ%�5Wv]���6��]����ů"�fdӴ��6��>�-{��gAa	�^+U�xϽ�~��E��}���i�-��h�e��1�ID1Lsg,8t
I�	q���j�6Y�U�
��"3��[�:t�O<���z������
�s�������4��g����8�a��z�����R�G�`6���j+R,���=O���ܶ��'F���d��@�����LPb����<`{w�W}��Gؾ�	��	u�glu���O���c���_�sl[�^§��&-�g?7��ZDL���q#�o�aR�V�\��M��Y��@�Yu������l]΅�@m�Ϥ-�'2KcߏQ\�S�B	���/a�8��3lbc�ð��g�&<����rk��{���)}��8�&�O�^ So�B j���>�\m�s>z~��q^a�.R����sk�vSL�������M��+G<g/B���c��c�¨P�����zG��h06�l�šV<�!N���w��5?D�x��;���c��Yq7w���NV��u'ю��D��n��F�&� =/���p�{��|#e޽��*��+����Ir< �AN���ui�ț^���0��D�~$ZT�W�F!�N��B�a��"���Q�DJtr;=[9M_�-b��� /��
=�Y�t9��|t��O��O�E�PT�U�3�-��T�<��Ӷ$/^������K��*'��춚�%4��E����Q�_H�u��뀷6>��,e
�S-������%vP)qX86��xN	���1%�*�qX�����}Z^S��k��ጼ7B�P�<�3!��+�6hNYE@�R��B�z�9����][I?��o�4jlo�PQ����W�{,�]B�����.�-[��1J�z�4�ݯ�^��bMH0��h��d��{�����R_�v�,<�r+����V>�z��cE}�#A f�:�3��c5�@������]&3�]�@�B��l4Q8����t^-���Pr�B-@�f�]��+b�de��(�Bg�PO�lhb����x����[�"���ʟ��!<"����ՊN���PvΒ;�<��:h3��[�Z��`�V\����~ĭXmLGuw���֕�U�.L���k�C�!j���2w�D�s0�E��n����=a�aq=(�����HY3��CTn�##��2�2,Q��_�����n�B!�U���y�z�u*���WU�(E�Y�a�)�����ϷY{�x�hT�u�t'�YjpT��;J?�}}�m8��h_��A8��
��9��qN��|��;���̉�ʞ�������i���6;���c��i��Ie�1���
��4	r�5����INX����S�U|:�^]ףu$��dZ�k3p�A9��Մ��ع��*�{ʲ�ѫ�M��9�f(��(�q�ǽ�3�ݗk)�W��6LR�&��Ca��g�յ�ؖ���7G�Y=~����E&}/�J�]�� :���ɢQe�^\��sj{l"���AP\㏢ɝi&�Hѫ�7�G��|{�ӱ�nSS�x����hu�[ ��pvw����5���0�*!�ޜ��[9/�N����h7��E����j��Ű8��m���K�fI����D�ԃ����3��qx���zJ�(��<�/w	�zp^lF��Nր�$ą�mE��M���Kc7����$	>����-v�Ռ0,�':f9	�S����kT���wA�H4�:��|%J#.����]��L���$��B�;�U.�S
��I�D����t�,��$y�w(���<����3{U�.��f+�*%����Ԓ&#R$����,��#�7W �@a�E�ؑg��S��ob; /*����HopX)���ꐒ�x�[ҫ�ўY1�>=�6e�ē�˰_mG?�pvMA�w֝[�B�����t5�ȿA�q�+Э�ɱ��?�U,t�X.Z����ϩ�~-���q~�
�|��]�<|j"�������U��^�B�2��A�@l.�IUC�@
JC�x��1������*�z� ���u����=�>�(=���=|���S֮�����-�=.낁[u@�#�N��.�uv(G����;���Cl����p��a$�	bKe����EC5�J�q�G��SE�N<sjɠ�hX�*g��j3w�2�{4ԹG�n��A�"�T�g�s�'(%�"�P�Y?���@]boH��(a���#uژ���h��Vl��$T�����8T�0���>F]���-�9t��|ӨQ��=ܕ.Kq���c���uK��~���>���'��7B�X�s�����)�>{u�Cא��w����� �H~���c�>8ؼy�uyBc��Y��ӭZ�W��`����Գu�3��]��5�Nkm�����an9�M3��3:�2ǡY"T�y"�B<�h�.�G~כ^�:\��t�ͤ��6�-/�)���V�.�f*���J.X��Q�n�=oP*�� ��;��ix�����Nێ�ė��#r�"#��q�r�A&tzz1L�ƶ5�.�n����y<�Fn��P�7V�l~㭟b�H��@ِ
n����U�i���@ �)�����V}�qM��[Y�u0��w��T6�CZӽc��vk�;Q� �������4>�ɀ⫓�|�8!�k������M%+t�.׋.����l�_Q#|��i'�G�uN�$p��{�Tz��Jc���l%�2N9�O}�錺��HPI���p|*[_^�m�ʫ[�6q�{�	,�d������F<w����>D���Mӟӗ.]��2���A�=Rq�lE���(��R-8C���m�jv14�����Y�jRڷ羷n[�2�`������F�:n!ޏJW럵4�./�W�����~�X#�V\u�_�w�.y|vi
TqCIWs�81��6F!>��>��bE�	?t?*̢�m��D���nq���1�a�|��	�'[��p�g����`z�
-�����~lH���ϲ���N���B@B�?WB b��������恔���Q����e�t�"��J�:Fn��i�kL5�&�z[V�������D�����u�:�o������	W.�*!�`_��S$n�Q��#W��R����&�/'�9MM��iԞ��	(����L���\g2��Y�I��;J�ȕD 1�}<��	j��1�wl�Ձ�����H}l�NÄn���+���ax�},��j+u��5L4��+ �0y_�X��gim�<���>K�r1%�}�|�0'z�C�{�ec�����c�����l&��0�l�P7��~߿��&z�'�f;g���у�X�p��B��.�����e]�O�AZ~���!�+���XI�v�x��+p\����R�/� O�������]
��)�7>��Is�jwg�:�T�B�o���/��bZ�9��N��;#&��|Ƴ�*Y�A��5W�������k���tj�R=�T~�֖W�Q
c��4�h���s&V�؀��G�+A#��"���{�U�6#{- �J3nO��V�ş���is�r���]���5^ԧ���jRX�&E�0-C_��N�dg$3U(�̱�^�.r)�]�iYqt���b��Z��%QDY�G��d�F0����k`b�C��*��(���C	��K�٭�Q�_T�#0
�[�Yhj�<^��]�_O޿8L�v��K?�^Bcu��>�5:���sB/�mk�$��ijk����=��<Z4q��B�w` /����'N�2֚_-�HS'�<���.q�Պ�n��]p�fy�3��Bkc�����5J����ڢ�P(�/��e��j7�<�|��1�Iih�"��߯ʅI�U�	���7�Ϧ[=J%��La��C8'~�>�W��ї��`\X)�V�#a*�ۚ��"�a�e~@����"��D�`,4�!s�15��1����`�]L�Nش5�i���[�!*y4���>�A�Yr��笏K�W5A} ��MB+,���ۣ�}Yz�/���ڦ���F�hx�N�m�\��
L���V��;}xS��k��C�R-O_M�Ģ� V1?$���ʔ�k@w���Yl#"8#��B�}�Rǭ̘vO�3L�ߌ�#�%����W��b���n�"tAp��-��x�4�<�ۛ*P���9?'$�O�}�/�!��qu�_���ҽL(���c�0�Pڄ��=R��ҙE��r��ߍ����$
����ڄ}?^��]�B)k:ی�t�zqY�wH��J�MH�cD� _�WKk�^�����zk=�m��W����e�d"�"
��������nW�>�����2d��|O�R*b�H}l�����M��WY�B�d;_�Ш�pۄ�#�tc:��o&'�Z���H�W���P��C	2����O�'��8&(�=�V���H���ݴ�7�HQ��iO��l/�� Ie��Q��Ǻ,�����G��Y�|�����u��W'��������ө�9$�v��$7hY\� UH�ᦂ��A\C�w�69���2.���HI�Ŕ���a������X\���E�r/����rc��e=���ԹP���v�8�_uV�im�+����b�G���݆�I�Y��-��j����C$j/�E�C��ob�հA;	�l-�2�A�z�8һC��MR�:�F�u%�v��C��X��׆Ee�zhn�����ޠ�~�B���3fV�.�{x��!|-�S�Xp'�1Ľ�y��p-p��928̥݈�L;/�@W�Q�O\��9�_E�����o����#I�	]�J�ǹ����\}h��D9(���U��u)�03>���.�r�((尠7����m)�����(��*ȏ�e�d�C�)�P�A3���ޙm����K�,�]�T�<O��Q�c:&�H����\�L�����QSF��B}�u�l�U��le:����5C����Ë� \�~R�-�E��w�ng��|*��:(����Ԅ��	ߕ�������U����Jר�El�?(n��ro�j��4r��/3�)m7_�V��f��K�?�z�4�"?����ꊓUmfV�<����k��a�"5��Y��`\,6��q��<�%��'�az2&��ڢ�
=tFȀ���hc3�2� ��O��jm��Ľޅ�>zR�r�"���9?�9�+�,�
؁�}=���r�}&��zٸ����j�k2���zx��\ߟ�6�n���a��	�T����~����!Z-n�[D%�gS�� �����j�L�J���,|�bG�M7�L��o�0ɢ\��gN�u��G�6�/��t�0*��NF-��>A��̺r!�x�<�x	Y3I<-\Dj&6ć�(���-k��_W�H��b�i����� Oq���}����y������SXl��	;�d�TD&)Z:�]�*�vҴ��Hf6´�`$��)�s;�^����E�c;����q��)����d@�D��.K�f|Hb����g�<�:13
���^�g�[�Y0a����L�t]S�����@�%����j�S@�t��3,&rI9�����ܕ.i�-�������8�EW�e�]�:��e��z���1�
�AX��H�4�D�`��ɋi۪	���+�P�R�gMl���	����{ej�&
����/�9�L�*i0�ݸD�J�l��+u��X�5:��Ɩ7�`7~�u*3��$����/>졩��vw��q��+�e�n�h�P�ىE'b6�������h2.�C��;c���n�`!��_��x��4{����K45N�L��
O
������ub	zH�oUf����p���U]Q/C�<3	��Y۫�Œk�(��=���Y-=�f�8�W �� ߳�y-�(�
��R6��Z���L|Wv߮�tw]��H&������Q�$�s�M̜C8�cK����*��Ri��Û�w
�s���C�~���nh[���r��+�g.��猏&�Iv�N'��U~�*4
�W?�/�0�+Ƹ�ږ���Y߭?Ih05'c��v�r�_�!�G^&0��L��t�H0�u"T������*�t�)b�绋

��9�ՊC����*�c�l@n�Y�Y����~�`Sqb�N�h�Ø��U	�������Z~�,�
�Ʒip�O��;����^Jj�P,I>�����jovo�
�wWΔ�R�;����(^*��������[ͨo�)�ҕ�7��d(��	�A��{�^m՗�nHT��5�e���B+�!�O�ñBѰח@~B~�uȽB"�y=P�[�*SS�R�;-P�a��H�+Z��b�~�:im���e�Q;{�ҎƱ�	_]�c�7m��5<fVf(`S��x�Hބ\W���A0?>Qͱ#���ZQ��3��<��xn�>�KLY��t�KK�hXf�cV<Q�(e>�w1U.z6_G@�!���ڭ�n/ɧs�K���3��(F`3�*��ΥL�14���0�O��y�<q�y��U�!��uP1�~W�)�K}Loau���<k(b�7ub�O�BX��(���I��:r���;\�t�;A!/��f���� h�b������,��8Z2d07�Q���!�{غ�:!��k�� E����1I3࣬��9��&�a诳��wVUY �l�r��5��6��40�.��^<�cU&��w���`Ѫy�X�%��f�rMD ֵRx����|��e�N��q��(�K�M�N��#ޓ��i$��/=�Be��VO�bx���Zsձ��.�]��X�%��k1��#��n��ߡ����L�����م���?�Y%�P���c�����%�"����dkc�\��AU�7ǀ�]��dD����nuRl�`���a>$�Y=CS���!��?�ȪXѺ�1�D裪@}����u?�8]�o畂wN��sz��d�鈘�KG؇�2t��wQ�����N��.@E;Ѕ�ne�&�((ƹB�;���4D��8�e�.��3q�E���`����Ff�o��k0�B;x��f�
~w ��r,�UAaepD����w��nhv�k�c�x��j�G�9����/�&�&X⼺ϫ�['���-�ِ���z�z�J8ynk�?�OH��S	�<Oәd��b@L�j�`\��Dd,6�3��\"�[�#�a�K�w,#��󨊒n���.�XUa�8|����#���4)��pX��Ͽ�KI�)O����]�D�i�
��~��"H<���B]��}�G���/�9��8��e1T�8+�6���`[�o��"�kW���ފ7�r�"v�o��ń,A=�HM�B��/z)�@ϞrD^��}Ѻ�T�p�:qO�z��LG�v��*���$�_�x59�?��H�x�j�S��w���Ǎ�e<ٙ����}���g���Q��(x?��i���@ ���Gu"M��xO�O�  ��$.5�[��q����ȼ��]��"C~�����r�^E\ ��!�]�a<<ž�%���nt�|u�s���C�A�C�a���f��7��������Ng���c���q)M=�ș���g�ЭK���v��\�F��t����
��R/N�C7���<���Ī��B�4��ѕ��F��^uB{b���)���#~2�X?3d�ߒ��:�*y��*<v��[�ݠ'O�x���T�P������jr�B_����� Y:�<ZA�4VLS�:B�b�R���¨R�2Fj��lW�ߢ�:�^�s��"�
��L+�0�z��C�f����]A�E��>4�ɨr�|�-�;��������p׳����ķ�Q�V�]N�n��;i驽�}�jb��2��k4��K�DJ��n,�a9���j�76nB��vL��ާ���8��f�9�[�"�,��j�m�i�P�*!����P���惕�諌ȕ�7Z�k���G�M��2���}.YU]��w�NԢr��b� ��BK*1��&�~��xw0�Mia����� ��rՐS=�z|@h��v�,�04c+�wM��ƪWp��d�ͅ���+a@�=�@(T�S����Q~>��K:�L<�s;�+��'��g���;�(zHY}�g�᚜'�5d����i�|=W\T�kڥV�h�(�c����J}Az�C�V��3��c�evM��Y�<�,�s���h��6�"�$o~�{�ʀ�ȷ���TӬ?�0�9jGa;w��e�QH�H�p)�Y��WE�>8�� %��D#��S�o��E`�0�E��N��. ���{	�(����4��Vj��SO�v�\�iz���*D3[�������5��K�P���+�<j�Nx;��F��u��n�Mf�
� �������3v�r���CyMj$U��儍r��o5I^�U$ #��G����w���M��X��[��[uNdz���5�K~�X�u	_�W�Q��wͪw�D�̛�B��l��8M����Y(��tm%1v����F	̌ط}o�ZFG�DGt��N<����S�m�v�K	��b!�f԰�<R#*nz����#$���S�~j	��8Q�F,'^ù��`e��{����p}�϶$م�_����n�����V"aQqjՍ�W^��"�%RU��2>�8�q�8m82O�=�n��j]���B6W�v�57�"[���1[�?(�=G!�B|֐y��<��E��t��ti��W̙Y�|)7��28��}��EV��R?�-7��Y�Γ��Ҕ�R?\�
-�		7�%'8�E�UYOx�|AS3�3m���?]��2��+�v����4���-*W&uqn�@�$�/ ���u��	->��0f�4XY����%X�+h?1��z(bv8�~ė����ŋb&+f���OL�2�M�5�}:��X���>�Z���;�|y@�<�n;Erz�'ce���U��C�Q��ڨ���[<.c���'F��q_�Ԯ��}�06�H.ɛ�Z�)�|�����[�:j�94"�y�_�o� �=R�j��D3�+ ����uZ=(˻�� Cd^��RjF���:+/Z��}!�c�X�Y[�Ir��vJ���v�M�zsXo>|M)a��v��>dƽ�KqU�h��Si剉�OF��$�8��(�]v0b�ѬӬ���⃱�g��X/M_c/yR@�\�Ao��>��87j,"�<�0NБn������8�A.��r�qctL���B�̰'J�+9�>��TTp������ò�iZ1��%6�����7^�&���b���4����s��*v�A@:T�lLH���<T`]!M����WH�g���C��� i�!
}2���,�H�[\:qPת�ˑ<�Fb����f6�hCF2nƒ33+�Km�O$�9E����홗�/V9��뇊��0j<��lz`vE'��cV�w$��'���&�\��<�����lOv�z�" ����#:��,�5�9+H">l����,�Z�dsj]�¯H�]�M���RW<'?�;b)��K��� M'i]�п��*��=j�:���R�X�_��'n{�ډq�]��O����'�J�L~����5�����\��Bz��P�+v{�LT�������e������aEƫa���(�P��S�Z�2�,�m�x�J�EQ���)�=/�J3˩�Qd���m��x �t<������g�@���	F3D�?r�4Xbt^9髌�v�;��N��$���h�_߰m-Q�:ҫh����?�0�v����(�";�ܩ���a?U@��r�(o6�%�~Dx�dT�4����zM�%��|������Q�\hY����%��ǵ�D#���\�)��%�R�����2��֜`���� � ����;��z�e>8����Ck(~T��T�\�V9��/�Zv��I��@V�4s�R�>�z�е�pjW��^7�W�����m������%��:�,�A���".�~}��i�tV�G�C7�5�ġ�S���գt�b�e� N@Hl �ݳğ�am�2����Ī�
2���Gh`\�7�L)�h=�hHu�nYk�r�ɜ� 0[�6\6Ǭ�0�q��8&�¡d08,B�г���wi0@D�m�z���SڐC��L@�A�YZ��f�B&i�R/���P��|?2�e�C�zΚ�o*�d<��.M�]��=NΦ�c�7�@�1�i���᱌���m�p)J�1z��,x�V����(�2O��To�++N��Zl�ͯ񅎯�J�-k��ݲ�ƇD�N����&��>���W<%�O���~��DZ�6�Ơ�8���z���k&ȩ�$}Q�Y�o� N���%��A?��u�;49~"r4�S��M�踷��|&��ۭL��(���@CkC��jn�,A�`Tǌ/_�$bs߽_9RӚ*���� ֛��L�7ⴐ%�Z��c9����^	O����?߼����(x�y\��x\�Bp~�E�!،;�~?��`��'�_u�T�g�͈\<���]XJ~PV�2���X> e
��ƽ�Ҙ�&.>Ns��j�A���n#*�TZte�K�53�کҫ���S���Y�6�w�U�uG��K�B8]M����Q�8�9��-�d/~H�Y�k�nv��@5���V���A��1/��{�)@�<݆�������!�mQ�n ��;����|[�k\@���/?A�"�w.�O���c2'��L��ͧ�&5��h�)�n����M�`��n}�bj�\��K��of�^�5�-E��Qh�����8f��n-aK�S�`54ɀm5��%J�R���Z`�~tU�׼��F�+1�<
>��Nb�%H�LT*�d�붔������Ϙ��"�m�y��҇92^b�~��O�,x�煝���5 K��hI�!��H�xP��[+�0y��kzk ��8љM��)/���
/	B�G]��8֖�WO���T� `�o{�FI�|��,�R��^�-�*�n\�H��-h�G����N,r�윚G�K�wm�K۞B�H>��C�w�@�.�H*������j�ߢ���	,���x\��?�n$T$[^�e�	Ĝj��j�r�QV���RA�"VY����h��ڄ�c��!c"Hg=��y�
N(�UrdS1�.��j%�į6�� x���&S��md!�V�M�b'��_�Ty�ؚ���p�6ɺ_8�N���<���OT�LvI�(F�	^\/S�+�{��F̓\<5�n뮚��As�j�IllV8R��:����
߶B��II�1<�ĸ��ΐ"PP/�A%��}� F�aYm ��u�"��{�A\�@ ���J��.��y~��}�&��A)a�U\NO�As��O��d����D-g���P3[?������:��߹�1c��W#�t�~+h(�,��s���-yn|��l�K�d5R7ڴd��<��W��K���H�v,vp�?^j<���o�l�|!����I���=�E�2�
�m*��ᗿ��f�I�Ҟ��~�_���U�xĘiZ��p�C�jK�,\��"���b'��/YR�x���͝ L�\�ь$D�wL��mTj�Q��1f�2��k0��9N��gF�.Q��ź�la$��7�L�۬\k��.(�Yw��f�?�R�e[
�h�e�k�j\2�EJd��5,%�#�?�J�m#كZ�:��0�¶�$af�+y�����Tk�E���m����v
x�]U��a
������@t�5��kM<��߇˛Ķ�zb�6�L.����4�r�uu�xq�_"�3�k� ]�ϐ��� ����	�rN��g�    YZ
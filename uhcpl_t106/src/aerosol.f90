!+ for the aerosol distibution.
!+ $Id: aerosol.f90,v 1.3 1998/10/28 12:27:04 m214003 Exp $

SUBROUTINE aerosol(paesc,paess,paelc,paels,paeuc,paeus,paedc,paeds)

  ! Description:
  !
  ! for the aerosol distibution.
  !
  ! Method:
  !
  ! This routine fetches values of a t10 spectral distribution
  ! for four aerosol types of different origins (sea,land,urban areas
  ! and deserts). The values to be obtained are between zero and one.
  !
  ! *aerosol* is called from *physc* at the first latitude row at
  ! the time of a full radiation computation.
  ! there are eight dummy arguments: 
  ! *paesc*, *paess*, *paelc*, *paels*, *paeuc*, *paeus*, *paedc* and *paeds*
  ! are arrays for the t10 distributions 
  ! (*s for sea, *l for land, *u for urban and *d for desert,
  ! *c for cosine and *s for sine).
  !
  ! Authors:
  !
  ! J. F. Geleyn, ECMWF, September 1982, original source
  ! L. Kornblueh, MPI, May 1998, f90 rewrite
  ! U. Schulzweida, MPI, May 1998, f90 rewrite
  ! 
  ! for more details see file AUTHORS
  !

  IMPLICIT NONE

  !  Array arguments 
  REAL :: paedc(66), paeds(55), paelc(66), paels(55), paesc(66), paess(55), &
&      paeuc(66), paeus(55)

  !  Local scalars: 
  INTEGER :: jmn

  !  Local arrays: 
  REAL :: zaedc(66), zaeds(55), zaelc(66), zaels(55), zaesc(66), zaess(55), &
&      zaeuc(66), zaeus(55)

  !  Data statements 
  ! *zae s/l/u/d c/s* corresponds to the *pae s/l/u/d c/s* (see above). 
  DATA zaesc/ + .6688E+00, -.1172E+00, -.1013E+00, + .1636E-01, -.3699E-01, &
&      + .1775E-01, -.9635E-02, + .1290E-02, + .4681E-04, -.9106E-04, &
&      + .9355E-04, -.7076E-01, -.1782E-01, + .1856E-01, + .1372E-01, &
&      + .8210E-04, + .2149E-02, + .4856E-03, + .2231E-03, + .1824E-03, &
&      + .1960E-05, + .2057E-01, + .2703E-01, + .2424E-01, + .9716E-02, &
&      + .1312E-02, -.8846E-03, -.3347E-03, + .6231E-04, + .6397E-04, &
&      -.3341E-02, -.1295E-01, -.4598E-02, + .3242E-03, + .8122E-03, &
&      -.2975E-03, -.7757E-04, + .7793E-04, + .4455E-02, -.1584E-01, &
&      -.2551E-02, + .1174E-02, + .1335E-04, + .5112E-04, + .5605E-04, &
&      + .7412E-04, + .1857E-02, -.1917E-03, + .4460E-03, + .1767E-04, &
&      -.5281E-04, -.5043E-03, + .2467E-03, -.2497E-03, -.2377E-04, &
&      -.3954E-04, + .2666E-03, -.8186E-03, -.1441E-03, -.1904E-04, &
&      + .3337E-03, -.1696E-03, -.2503E-04, + .1239E-03, -.9983E-04, &
&      -.5283E-04/
  DATA zaess/ -.3374E-01, -.3247E-01, -.1012E-01, + .6002E-02, + .5190E-02, &
&      + .7784E-03, -.1090E-02, + .3294E-03, + .1719E-03, -.5866E-05, &
&      -.4124E-03, -.3742E-01, -.5054E-02, + .3430E-02, + .5513E-03, &
&      -.6235E-03, + .2892E-03, -.9730E-04, + .7078E-04, -.3300E-01, &
&      + .5104E-03, -.2156E-02, -.3194E-02, -.5079E-03, -.5517E-03, &
&      + .4632E-04, + .5369E-04, -.2731E-01, + .5126E-02, + .2241E-02, &
&      -.5789E-03, -.3048E-03, -.1774E-03, + .1946E-05, -.8247E-02, &
&      + .2338E-02, + .1021E-02, + .1575E-04, + .2612E-05, + .1995E-04, &
&      -.1319E-02, + .1384E-02, -.4159E-03, -.2337E-03, + .5764E-04, &
&      + .1495E-02, -.3727E-03, + .6075E-04, -.4642E-04, + .5368E-03, &
&      -.7619E-04, + .3774E-04, + .1206E-03, -.4104E-06, + .2158E-04/
  DATA zaelc/ + .1542E+00, + .8245E-01, -.1879E-03, + .4864E-02, -.5527E-02, &
&      -.7966E-02, -.2683E-02, -.2011E-02, -.8889E-03, -.1058E-03, -.1614E-04, &
&      + .4206E-01, + .1912E-01, -.9476E-02, -.6780E-02, + .1767E-03, &
&      -.5422E-03, -.7753E-03, -.2106E-03, -.9870E-04, -.1721E-04, -.9536E-02, &
&      -.9580E-02, -.1050E-01, -.5747E-02, -.1282E-02, + .2248E-03, &
&      + .1694E-03, -.4782E-04, -.2441E-04, + .5781E-03, + .6212E-02, &
&      + .1921E-02, -.1102E-02, -.8145E-03, + .2497E-03, + .1539E-03, &
&      -.2538E-04, -.3993E-02, + .9777E-02, + .4837E-03, -.1304E-02, &
&      + .2417E-04, -.1370E-04, -.3731E-05, + .1922E-02, -.5167E-03, &
&      + .4295E-03, -.1888E-03, + .2427E-04, + .4012E-04, + .1529E-02, &
&      -.2120E-03, + .8166E-04, + .2579E-04, + .3488E-04, + .2140E-03, &
&      + .2274E-03, -.3447E-05, -.1075E-04, -.1018E-03, + .2864E-04, &
&      + .3442E-04, -.1002E-03, + .7117E-04, + .2045E-04/
  DATA zaels/ + .1637E-01, + .1935E-01, + .1080E-01, + .2784E-02, &
&      + .1606E-03, + .1860E-02, + .1263E-02, -.2707E-03, -.2290E-03, &
&      -.9761E-05, -.7317E-02, + .2465E-01, + .6799E-02, -.1913E-02, &
&      + .1382E-02, + .6691E-03, + .1414E-03, + .3527E-04, -.5210E-04, &
&      + .1873E-01, + .2977E-02, + .4650E-02, + .2509E-02, + .3680E-03, &
&      + .1481E-03, -.6594E-04, -.5634E-04, + .1592E-01, -.1875E-02, &
&      -.1093E-02, + .3022E-03, + .2625E-03, + .3252E-04, -.3803E-04, &
&      + .4218E-02, -.1843E-02, -.1351E-02, -.2952E-03, -.8171E-05, &
&      -.1473E-04, + .9076E-03, -.1057E-02, + .2676E-03, + .1307E-03, &
&      -.3628E-04, -.9158E-03, + .4335E-03, + .2927E-04, + .6602E-04, &
&      -.3570E-03, + .5760E-04, -.3465E-04, -.8535E-04, -.2011E-04, &
&      + .6612E-06/
  DATA zaeuc/ + .8005E-01, + .7095E-01, + .2014E-01, -.1412E-01, -.2425E-01, &
&      -.1332E-01, -.2904E-02, + .5068E-03, + .9369E-03, + .4114E-03, &
&      + .7549E-04, + .1922E-01, + .2534E-01, + .2088E-01, + .1064E-01, &
&      + .1063E-02, -.2526E-02, -.2091E-02, -.9660E-03, -.2030E-03, &
&      + .3865E-04, -.9900E-02, -.5964E-02, + .2223E-02, + .4941E-02, &
&      + .3277E-02, + .1038E-02, -.1480E-03, -.2844E-03, -.1208E-03, &
&      + .3999E-02, + .6282E-02, + .2813E-02, + .1475E-02, + .4571E-03, &
&      -.1349E-03, -.9011E-04, -.1936E-04, + .1994E-02, + .3540E-02, &
&      + .8837E-03, + .1992E-03, + .3092E-04, -.7979E-04, -.2664E-04, &
&      -.5006E-04, + .6447E-03, + .5550E-03, + .1197E-03, + .6657E-04, &
&      + .1488E-04, -.9141E-04, -.2896E-03, -.1561E-03, -.6524E-04, &
&      -.1559E-04, -.1082E-03, -.4126E-03, -.1732E-03, -.8286E-04, -.1993E-04, &
&      + .3850E-04, + .2870E-04, + .4493E-04, + .4721E-04, + .1338E-04/
  DATA zaeus/ + .6646E-02, + .8373E-02, + .5463E-02, + .4554E-02, &
&      + .3301E-02, + .5725E-03, -.7482E-03, -.6222E-03, -.2603E-03, &
&      -.5127E-04, -.3849E-04, + .9741E-02, + .8190E-02, + .5712E-02, &
&      + .3039E-02, + .5290E-03, -.2044E-03, -.2309E-03, -.1160E-03, &
&      + .9160E-02, + .1286E-01, + .1170E-01, + .5491E-02, + .1393E-02, &
&      -.6288E-04, -.2715E-03, -.1047E-03, + .4873E-02, + .3545E-02, &
&      + .3069E-02, + .1819E-02, + .6947E-03, + .1416E-03, -.1538E-04, &
&      -.4351E-03, -.1907E-02, -.5774E-03, -.2247E-03, + .5345E-04, &
&      + .9052E-04, -.3972E-04, -.9665E-04, + .7912E-04, -.1094E-04, &
&      -.6776E-05, + .2724E-03, + .1973E-03, + .6837E-04, + .4313E-04, &
&      -.7174E-05, + .8527E-05, -.2160E-05, -.7852E-04, + .3453E-06, &
&      -.2402E-05/
  DATA zaedc/ + .2840E-01, + .1775E-01, -.1069E-01, -.1553E-01, -.3299E-02, &
&      + .3583E-02, + .2274E-02, + .5767E-04, -.3678E-03, -.1050E-03, &
&      + .2133E-04, + .2326E-01, + .1566E-01, -.3130E-02, -.8253E-02, &
&      -.2615E-02, + .1247E-02, + .1059E-02, + .1196E-03, -.1303E-03, &
&      -.5094E-04, + .1185E-01, + .7238E-02, -.1562E-02, -.3665E-02, &
&      -.1182E-02, + .4678E-03, + .4448E-03, + .8307E-04, -.3468E-04, &
&      + .5273E-02, + .3037E-02, -.4014E-03, -.1202E-02, -.4647E-03, &
&      + .5148E-04, + .1014E-03, + .2996E-04, + .2505E-02, + .1495E-02, &
&      + .2438E-03, -.1223E-03, -.7669E-04, -.1638E-04, + .1869E-05, &
&      + .1094E-02, + .6131E-03, + .1508E-03, + .1765E-04, + .1360E-05, &
&      -.7998E-06, + .4475E-03, + .2737E-03, + .6430E-04, -.6759E-05, &
&      -.6761E-05, + .1992E-03, + .1531E-03, + .4828E-04, + .5103E-06, &
&      + .7454E-04, + .5917E-04, + .2152E-04, + .9300E-05, + .9790E-05, &
&      -.8853E-05/
  DATA zaeds/ + .9815E-02, + .8436E-02, + .1087E-02, -.2717E-02, -.1755E-02, &
&      -.1559E-03, + .2367E-03, + .8808E-04, + .2001E-05, -.1244E-05, &
&      + .1041E-01, + .8039E-02, + .1005E-02, -.1981E-02, -.1090E-02, &
&      + .1595E-05, + .1787E-03, + .4644E-04, -.1052E-04, + .6593E-02, &
&      + .3983E-02, -.1527E-03, -.1235E-02, -.5078E-03, + .3649E-04, &
&      + .1005E-03, + .3182E-04, + .3225E-02, + .1672E-02, -.7752E-04, &
&      -.4312E-03, -.1872E-03, -.1666E-04, + .1872E-04, + .1133E-02, &
&      + .5643E-03, + .7747E-04, -.2980E-04, -.2092E-04, -.8590E-05, &
&      + .2988E-03, + .6714E-04, -.6249E-05, + .1052E-04, + .8790E-05, &
&      + .1569E-03, -.1175E-04, -.3033E-04, -.9777E-06, + .1101E-03, &
&      + .6827E-05, -.1023E-04, + .4231E-04, + .4905E-05, + .6229E-05/


  !  Executable statements 

!-- 1. Identity P=Z

  DO jmn = 1, 66
    paesc(jmn) = zaesc(jmn)
    paelc(jmn) = zaelc(jmn)
    paeuc(jmn) = zaeuc(jmn)
    paedc(jmn) = zaedc(jmn)
  END DO
  DO jmn = 1, 55
    paess(jmn) = zaess(jmn)
    paels(jmn) = zaels(jmn)
    paeus(jmn) = zaeus(jmn)
    paeds(jmn) = zaeds(jmn)

  END DO

  RETURN
END SUBROUTINE aerosol

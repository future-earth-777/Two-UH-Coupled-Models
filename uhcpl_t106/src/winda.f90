	subroutine winda(taux,tauy,qsol,sflux,wind,ia,ja,fu_sst) 
!c--------------------------------------------------------------
!c    interpolating the atmospheric outputs to the
!c          oceanic grid
!c==============================================================

	USE mo_landsea,      ONLY: bzone, aland, iland, itopo, &
                                  agx, agy, sgx, sgy
	USE mo_doctor,       ONLY: nout

	parameter (io=720,jo=121)
!	integer aland,bzone
	real*4 taux1(ia,ja),tauy1(ia,ja),qsol1(ia,ja),&
         sflux1(ia,ja),tx1(io,jo),ty1(io,jo),qsl1(io,jo),&
         flux1(io,jo)
	dimension taux(ia,ja),tauy(ia,ja),qsol(ia,ja),&
         sflux(ia,ja),wind(ia,ja),fu_sst(ia,ja)
	dimension hlp(ia,jo),hlp1(ia,jo),hlp2(ia,jo),hlp3(ia,jo)&
                    ,hlp4(ia,jo),hlp5(ia,jo)
!	common /csbc1/aland(ia,ja),itopo(io,jo),&
!            iland(ia,ja),agx(ia),agy(ja),sgx(io),sgy(jo)
	common /scouple/tauxa(io,jo),tauya(io,jo),wfua(io,jo),qsla(io,jo),&
         fluxa(io,jo),sst_nudg(io,jo)
        common /fulat/jbs, jbe


!c	data jbs/34/
!c	data jbe/15/
	data ii2/2/
	data rho/1.2/
        data cd/1.3e-3/
!c=============================================================
!c===>interplating in y direction
!c	call view(bzone,1,ia,1,ja,1)
!c	call viewtop(itopo,1,io,jo,1,-1)
!c==>set taux,tauy=zero over land mass(bzone=x1)
	do i=1,ia
	do j=1,ja
	if(bzone(i,j).ne.1) then
	taux(i,j)=0.
	tauy(i,j)=0.
	end if
	
	end do
	end do
!c===>set coastal taux, tauy as the interior oceanic value
!c===> fu (8/26/99)
	do i=1,ia
	do j=1,ja
	if(bzone(i,j).eq.0) then
!c==>check left
	if(bzone(i-1,j).eq.1) then
	taux(i,j)=taux(i-1,j)
	tauy(i,j)=tauy(i-1,j)
	wind(i,j)=wind(i-1,j)
	fu_sst(i,j)=fu_sst(i-1,j)
	goto 33
	end if
!c==>check left
	if(bzone(i+1,j).eq.1) then
	taux(i,j)=taux(i+1,j)
	tauy(i,j)=tauy(i+1,j)
	wind(i,j)=wind(i+1,j)
	fu_sst(i,j)=fu_sst(i+1,j)
	goto 33
	end if
!c==>check left
	if(bzone(i,j-1).eq.1) then
	taux(i,j)=taux(i,j-1)
	tauy(i,j)=tauy(i,j-1)
	wind(i,j)=wind(i,j-1)
	fu_sst(i,j)=fu_sst(i,j-1)
	goto 33
	end if
!c==>check left
	if(bzone(i,j+1).eq.1) then
	taux(i,j)=taux(i,j+1)
	tauy(i,j)=tauy(i,j+1)
	wind(i,j)=wind(i,j+1)
	fu_sst(i,j)=fu_sst(i,j+1)
	goto 33
	end if

	end if
33      end do
	end do
!c===================================================>
	do j=1,jo
        do i=1,ia
	   hlp(i,j)=0.
	   hlp1(i,j)=0.
	   hlp2(i,j)=0.
 	   hlp3(i,j)=0.
 	   hlp4(i,j)=0.
 	   hlp5(i,j)=0.

!c--find the atmospheric grids in y direction
	   do 10 jj=jbe,jbs
	   jmm=ja-jj+1
!c	   if(j.eq.31) then
!c	   print*,'j,sgy(j),agy1,agy2=',j,sgy(j),agy(jmm),agy(jmm-1)
!c	   print*,'taux1,taux2',taux(i,jmm),taux(i,jmm-1)
!c	   end if
	   if(sgy(j).ge.agy(jmm).and.sgy(j).lt.agy(jmm-1)) then
!c-----taux
	   aa1=taux(i,jmm)
	   aa2=taux(i,jmm-1)
	   hlp(i,j)=aa1+(aa2-aa1)*(sgy(j)-agy(jmm))/(agy(jmm-1)-agy(jmm))
	   
!c	   if(j.eq.31) then
!c	   print*,'i,j,sgy(j),agy1,agy2=',i,j,sgy(j),agy(jmm),agy(jmm-1)
!c	   print*,'i,aa1,aa2,hlp',i,aa1,aa2,hlp(i,j)
!c	   end if
!c-----tauy
	   aa1=tauy(i,jmm)
	   aa2=tauy(i,jmm-1)
	   hlp1(i,j)=aa1+(aa2-aa1)*(sgy(j)-agy(jmm))/(agy(jmm-1)-agy(jmm))
!c-----qsol
	   aa1=qsol(i,jmm)
	   aa2=qsol(i,jmm-1)
	   hlp2(i,j)=aa1+(aa2-aa1)*(sgy(j)-agy(jmm))/(agy(jmm-1)-agy(jmm))
!c-----sflux
	   aa1=sflux(i,jmm)
	   aa2=sflux(i,jmm-1)
	   hlp3(i,j)=aa1+(aa2-aa1)*(sgy(j)-agy(jmm))/(agy(jmm-1)-agy(jmm))
	   
!c-----wind
	   aa1=wind(i,jmm)
	   aa2=wind(i,jmm-1)
	   hlp4(i,j)=aa1+(aa2-aa1)*(sgy(j)-agy(jmm))/(agy(jmm-1)-agy(jmm))
!c-----sst
	   aa1=fu_sst(i,jmm)
	   aa2=fu_sst(i,jmm-1)
	   hlp5(i,j)=aa1+(aa2-aa1)*(sgy(j)-agy(jmm))/(agy(jmm-1)-agy(jmm))
!c==================================================================
	   end if

10         continue 
        end do
	end do
	WRITE(nout,*)'FINISH Y DIRECTION!!!'
!c=========================================================================
!c===>interplating in x direction
	do i=1,io
        do j=1,jo

	   tauxa(i,j)=0.
	   tauya(i,j)=0.
	   qsla(i,j)=0.
	   fluxa(i,j)=0.
	   wfua(i,j)=0.
	   sst_nudg(i,j)=0.
!c--find the atmospheric grids in x direction
	   if(i.eq.1.and.itopo(i,j).gt.0) then

	   tauxa(1,j)=hlp(1,j)      !start from 0
	   tauya(1,j)=hlp1(1,j)      !start from 0
	   qsla(1,j)=hlp2(1,j)      !start from 0
	   fluxa(1,j)=hlp3(1,j)      !start from 0
	   wfua(1,j)=hlp4(1,j)      !start from 0
	   sst_nudg(1,j)=hlp5(1,j)      !start from 0
	   goto 78
	   end if

	   if(sgx(i).gt.agx(ia).and.itopo(i,j).gt.0) then
	   ax=360.+agx(1)
!c---------tx
	   aa1=hlp(ia,j)
	   aa2=hlp(1,j)
	   tauxa(i,j)=aa1+(aa2-aa1)*(sgx(i)-agx(ia))/(ax-agx(ia))
!c---------ty
	   aa1=hlp1(ia,j)
	   aa2=hlp1(1,j)
	   tauya(i,j)=aa1+(aa2-aa1)*(sgx(i)-agx(ia))/(ax-agx(ia))
!c---------qsl
	   aa1=hlp2(ia,j)
	   aa2=hlp2(1,j)
	   qsla(i,j)=aa1+(aa2-aa1)*(sgx(i)-agx(ia))/(ax-agx(ia))
!c---------flux
	   aa1=hlp3(ia,j)
	   aa2=hlp3(1,j)
	   fluxa(i,j)=aa1+(aa2-aa1)*(sgx(i)-agx(ia))/(ax-agx(ia))
!c---------wind
	   aa1=hlp4(ia,j)
	   aa2=hlp4(1,j)
	   wfua(i,j)=aa1+(aa2-aa1)*(sgx(i)-agx(ia))/(ax-agx(ia))
!c---------sst
	   aa1=hlp5(ia,j)
	   aa2=hlp5(1,j)
	   sst_nudg(i,j)=aa1+(aa2-aa1)*(sgx(i)-agx(ia))/(ax-agx(ia))
!c============================================
	   goto 78
	   end if

	   if(itopo(i,j).gt.0) then 

	   do 20 ii=ii2,ia
	   ia1=ii-1
	   ib=ii
	   
	   if(sgx(i).gt.agx(ia1).and.sgx(i).le.agx(ib)) then
!c	   ii2=ib

!c----------tx	
	   aa1=hlp(ia1,j)
	   aa2=hlp(ib,j)
	   tauxa(i,j)=aa1+(aa2-aa1)*(sgx(i)-agx(ia1))/(agx(ib)-agx(ia1))
!c	   if(j.eq.31) then
!c	   print*,'i,j,sgx(i),agx1,agx2=',i,j,sgx(i),agx(ia1),agx(ib)
!c	   print*,'i,aa1,aa2,tauxa',i,aa1,aa2,tauxa(i,j)
!c	   end if
!c----------ty	
	   aa1=hlp1(ia1,j)
	   aa2=hlp1(ib,j)
	   tauya(i,j)=aa1+(aa2-aa1)*(sgx(i)-agx(ia1))/(agx(ib)-agx(ia1))
!c----------qsl
	   aa1=hlp2(ia1,j)
	   aa2=hlp2(ib,j)
	   qsla(i,j)=aa1+(aa2-aa1)*(sgx(i)-agx(ia1))/(agx(ib)-agx(ia1))
!c----------flux
	   aa1=hlp3(ia1,j)
	   aa2=hlp3(ib,j)
	   fluxa(i,j)=aa1+(aa2-aa1)*(sgx(i)-agx(ia1))/(agx(ib)-agx(ia1))
!c----------wind
	   aa1=hlp4(ia1,j)
	   aa2=hlp4(ib,j)
	   wfua(i,j)=aa1+(aa2-aa1)*(sgx(i)-agx(ia1))/(agx(ib)-agx(ia1))
!c----------sst
	   aa1=hlp5(ia1,j)
	   aa2=hlp5(ib,j)
	   sst_nudg(i,j)=aa1+(aa2-aa1)*(sgx(i)-agx(ia1))/(agx(ib)-agx(ia1))
!c==========================================
	   end if

!c	   print*,'atmos=>ocean problem 2 in ocean.i?????'
20      continue 
	end if
78      continue	
        end do
	end do
!c=========transfer the units of the atmospheric model to 
!c        ocean model
!c========adjust the tx,ty
!c	do i=1,io
!c	do j=1,jo
!c	aa=sqrt(tauxa(i,j)*tauxa(i,j)+tauya(i,j)*tauya(i,j))
!c	if(aa.gt.2.0) then
!c	tauxa(i,j)=tauxa(i,j)*2.0/aa
!c	tauya(i,j)=tauya(i,j)*2.0/aa
!c	end if
!c	end do
!c	end do
!c-------------------------------------------------
	do i=1,io
	   do j=1,jo
!	   wfua(i,j)=4.
	   if(itopo(i,j).gt.0) then
!c---transfer wind stress to scalar windspeed
!	   uu1=sqrt(tauxa(i,j)*tauxa(i,j)+&
!                tauya(i,j)*tauya(i,j))/rho/cd/10. 
!	   wfua(i,j)=sqrt(uu1)
	   if(wfua(i,j).lt.3.) wfua(i,j)=3.      !minimum windspeed
	   end if
	   end do
         end do

!c------------------------------------------------------------------c
	WRITE(nout,*)'oceanic inputs at (130,31):'
	WRITE(nout,*)'tx,ty(dyn/cm**2)',tauxa(130,31),tauya(130,31),'Uwind',wfua(130,31),&
        'qsol',qsla(130,31),'hflux',fluxa(130,31),'nudg-sst',sst_nudg(130,31),&
        'sea=',itopo(130,31)
!c===================================================================
!c	print*,'taux=',(taux(i,25),i=1,96,3)
!c	print*,'agy=',(agy(i),i=1,48,1)
!c	print*,'hlp=',(hlp(i,31),i=1,96,3)
!c	WRITE(nout,*)'Uocean=',(tauxa(i,31),i=1,180,2)
!c	print*,'sgy=',(sgy(i),i=1,61,1)
!c	call viewtau(taux,1,ia,1,ja,1)
!c	call viewtx(tauxa,1,io,jo,1,-1)
!c--------------------------------------------------------------------
!c    deposit the atmospheric outputs
!c	do i=1,ia
!c	do j=1,ja
!c	taux1(i,j)=taux(i,j)
!c	tauy1(i,j)=tauy(i,j)
!c	qsol1(i,j)=qsol(i,j)
!c	sflux1(i,j)=sflux(i,j)
!c	end do
!c	end do
!c	do i=1,io
!c	do j=1,jo
!c	tx1(i,j)=tauxa(i,j)
!c	ty1(i,j)=tauya(i,j)
!c	qsl1(i,j)=qsla(i,j)
!c	flux1(i,j)=fluxa(i,j)
!c	end do
!c	end do
!c        open(22,file='atmos.dat',form='unformatted',
!c     1    access='sequential')
!c	write(122) ((taux1(i,j),i=1,ia),j=1,ja)
!c	write(122) ((tauy1(i,j),i=1,ia),j=1,ja)
!c	write(122) ((qsol1(i,j),i=1,ia),j=1,ja)
!c	write(122) ((sflux1(i,j),i=1,ia),j=1,ja)
!c	close(22)
!c        open(23,file='ocean.dat',form='unformatted',
!c     1    access='sequential')
!c	write(123) ((tx1(i,j),i=1,io),j=1,jo)
!c	write(123) ((ty1(i,j),i=1,io),j=1,jo)
!c	write(123) ((qsl1(i,j),i=1,io),j=1,jo)
!c	write(123) ((flux1(i,j),i=1,io),j=1,jo)
!c	close(23)
!c	stop
!c===================================================================
	return
	end

	subroutine viewtau(ala,is,ie,js,je,jv)
	parameter(ima=96,jma=48)
	dimension ala(ima,jma)
	integer*1 alam(ima,jma)

	do i=1,ima
	do j=1,jma
	alam(i,j)=int(ala(i,j)*10.)
	end do
	end do

	im=ima/2
	write(6,110)
110     format(/, 1x,'Atmospheric taux follows:'/)

	write(6,120)((alam(i,j),i=is,ie),j=js,je,jv)
120     format(1x,96i1)

!c======save for print-out
	write(12,111)
111     format(//////, 1x,'Atmospheric land/sea mask follows:'////)

	write(12,121)((alam(i,j),i=is,im),j=js,je,jv)
121     format(1x,48i1)
	write(12,111)
	write(12,123)((alam(i,j),i=im,ie),j=js,je,jv)
123     format(1x,49i1)


	return
	end
  
	subroutine viewtx(top,is,ie,js,je,jv)
	parameter(ima=720,jma=121)
	dimension top(ima,jma)
	integer*1 topm(ima,jma)

	do i=1,ima
	do j=1,jma
	topm(i,j)=int(top(i,j)*10.)
	end do
	end do

	write(6,110)
110     format(/, 1x,'Oceanic tx follows:'/)

	write(6,120)((topm(i,j),i=is,ie,2),j=js,je,jv)
120     format(1x,90i1)

!c======save for print-out
!c	write(12,111)
111     format(//////, 1x,'Oceanic land/sea mask follows:'////)

	write(12,121)((topm(i,j),i=is,60),j=js,je,jv)
121     format(1x,60i1)

!c	write(12,111)
	write(13,121)((topm(i,j),i=61,120),j=js,je,jv)

!c	write(12,111)
	write(14,121)((topm(i,j),i=121,ie),j=js,je,jv)

	return
	end

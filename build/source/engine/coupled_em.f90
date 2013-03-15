module coupled_em_module
USE nrtype
implicit none
private
public::coupled_em
contains

 ! ************************************************************************************************
 ! new subroutine: run the coupled energy-mass model for one timestep
 ! ************************************************************************************************
 subroutine coupled_em(dt_init,err,message)
 USE data_struc,only:forcFileInfo                                     ! extract time step of forcing data
 USE data_struc,only:model_decisions                                  ! model decision structure
 USE data_struc,only:mpar_data,mvar_data,indx_data,ix_soil,ix_snow    ! data structures
 USE var_lookup,only:iLookDECISIONS                                   ! named variables for elements of the decision structure
 USE var_lookup,only:iLookPARAM,iLookMVAR,iLookINDEX                  ! named variables for structure elements
 USE newsnwfall_module,only:newsnwfall      ! compute new snowfall
 USE layerMerge_module,only:layerMerge      ! merge snow layers if they are too thin
 USE picardSolv_module,only:picardSolv      ! provide access to the Picard solver
 USE qTimeDelay_module,only:qOverland       ! provide access to the routing module
 USE multiconst,only:iden_water,iden_ice    ! intrinsic density of water and icei
 ! look-up values for the numerical method
 USE mDecisions_module,only:      &
  iterative,                      &         ! iterative
  nonIterative,                   &         ! non-iterative
  iterSurfEnergyBal                         ! iterate only on the surface energy balance

 implicit none
 ! define output
 real(dp),intent(inout)               :: dt_init                ! used to initialize the size of the sub-step
 integer(i4b),intent(out)             :: err                    ! error code
 character(*),intent(out)             :: message                ! error message
 ! control the length of the sub-step
 real(dp)                             :: dt                     ! length of time step (seconds)
 real(dp)                             :: dt_sub                 ! length of the sub-step (seconds)
 real(dp)                             :: dt_done                ! length of time step completed (seconds)
 integer(i4b)                         :: nsub                   ! number of sub-steps
 integer(i4b)                         :: niter                  ! number of iterations
 integer(i4b),parameter               :: n_inc=5                ! minimum number of iterations to increase time step
 integer(i4b),parameter               :: n_dec=9                ! maximum number of iterations to decrease time step
 real(dp),parameter                   :: F_inc = 1.25_dp        ! factor used to increase time step
 real(dp),parameter                   :: F_dec = 0.5_dp         ! factor used to decrease time step
 integer(i4b)                         :: maxiter                ! maxiumum number of iterations
 integer(i4b)                         :: iSnow                  ! index for snow layers
 ! local pointers to model forcing data
 real(dp),pointer                     :: scalarRainfall         ! rainfall flux (kg m-2 s-1)
 real(dp),pointer                     :: scalarSnowfall         ! snowfall flux (kg m-2 s-1)
 ! local pointers to model index variables
 integer(i4b),pointer                 :: nSoil                  ! number of soil layers
 integer(i4b),pointer                 :: nSnow                  ! number of snow layers
 integer(i4b),pointer                 :: nLayers                ! number of layers
 integer(i4b),pointer                 :: layerType(:)           ! type of the layer (ix_soil or ix_snow)
 ! local pointers to model state variables -- all layers
 real(dp),pointer                     :: mLayerTemp(:)          ! temperature of each layer (K)
 real(dp),pointer                     :: mLayerDepth(:)         ! depth of each layer (m)
 real(dp),pointer                     :: mLayerVolFracIce(:)    ! volumetric fraction of ice in each layer (-)
 real(dp),pointer                     :: mLayerVolFracLiq(:)    ! volumetric fraction of liquid water in each layer (-) 
 ! local pointers to flux variables
 real(dp),pointer                     :: scalarGroundEvaporation ! ground evaporation/condensation - below canopy or non-vegetated (kg m-2 s-1)
 real(dp),pointer                     :: scalarGroundSublimation ! ground sublimation/frost - below canopy or non-vegetated (kg m-2 s-1)
 real(dp),pointer                     :: scalarRainPlusMelt     ! rain plus melt, as input to soil before calculating surface runoff (m s-1)
 real(dp),pointer                     :: scalarSurfaceRunoff    ! surface runoff (m s-1) 
 real(dp),pointer                     :: scalarSoilInflux       ! influx of water at the top of the soil profile (m s-1)
 real(dp),pointer                     :: scalarSoilBaseflow     ! total baseflow from throughout the soil profile (m s-1)
 real(dp),pointer                     :: scalarSoilDrainage     ! drainage from the bottom of the soil profile (m s-1)
 real(dp),pointer                     :: scalarSoilEjection     ! ejected water from the soil matrix (m s-1)
 real(dp),pointer                     :: scalarAquiferRecharge  ! recharge to the aquifer (m s-1)
 real(dp),pointer                     :: scalarAquiferBaseflow  ! baseflow from the aquifer (m s-1)
 ! local pointers to timestep-average flux variables
 real(dp),pointer                     :: averageGroundEvaporation ! ground evaporation/condensation - below canopy or non-vegetated (kg m-2 s-1)
 real(dp),pointer                     :: averageGroundSublimation ! ground sublimation/frost - below canopy or non-vegetated (kg m-2 s-1)
 real(dp),pointer                     :: averageRainPlusMelt    ! rain plus melt, as input to soil before calculating surface runoff (m s-1)
 real(dp),pointer                     :: averageSurfaceRunoff   ! surface runoff (m s-1) 
 real(dp),pointer                     :: averageSoilInflux      ! influx of water at the top of the soil profile (m s-1)
 real(dp),pointer                     :: averageSoilBaseflow    ! total baseflow from throughout the soil profile (m s-1)
 real(dp),pointer                     :: averageSoilDrainage    ! drainage from the bottom of the soil profile (m s-1)
 real(dp),pointer                     :: averageSoilEjection    ! ejected water from the soil matrix (m s-1)
 real(dp),pointer                     :: averageAquiferRecharge ! recharge to the aquifer (m s-1)
 real(dp),pointer                     :: averageAquiferBaseflow ! baseflow from the aquifer (m s-1)
 ! local pointers to algorithmic control parameters
 real(dp),pointer                     :: minstep                ! minimum time step length (s)
 real(dp),pointer                     :: maxstep                ! maximum time step length (s)
 ! define local variables
 character(len=256)                   :: cmessage               ! error message
 real(dp),dimension(:),allocatable    :: arrTemp                ! temporary array, used for testing
 real(dp)                             :: dt_wght                ! weight applied to each sub-step, to compute time step average
 integer(i4b)                         :: iLayer                 ! index of model layers
 ! initialize error control
 err=0; message="coupled_em/"

 ! assign pointers to model diagnostic variables -- surface scalars 
 scalarRainfall    => mvar_data%var(iLookMVAR%scalarRainfall)%dat(1)     ! rainfall flux (kg m-2 s-1)
 scalarSnowfall    => mvar_data%var(iLookMVAR%scalarSnowfall)%dat(1)     ! snowfall flux (kg m-2 s-1)

 ! assign pointers to timestep-average model fluxes
 averageGroundEvaporation => mvar_data%var(iLookMVAR%averageGroundEvaporation)%dat(1) ! ground evaporation/condensation - below canopy or non-vegetated (kg m-2 s-1)
 averageGroundSublimation => mvar_data%var(iLookMVAR%averageGroundSublimation)%dat(1) ! ground sublimation/frost - below canopy or non-vegetated (kg m-2 s-1)
 averageRainPlusMelt      => mvar_data%var(iLookMVAR%averageRainPlusMelt)%dat(1)      ! rain plus melt, as input to soil before calculating surface runoff (m s-1)
 averageSurfaceRunoff     => mvar_data%var(iLookMVAR%averageSurfaceRunoff)%dat(1)     ! surface runoff (m s-1)
 averageSoilInflux        => mvar_data%var(iLookMVAR%averageSoilInflux)%dat(1)        ! influx of water at the top of the soil profile (m s-1)
 averageSoilBaseflow      => mvar_data%var(iLookMVAR%averageSoilBaseflow)%dat(1)      ! total baseflow from throughout the soil profile (m s-1)
 averageSoilDrainage      => mvar_data%var(iLookMVAR%averageSoilDrainage)%dat(1)      ! drainage from the bottom of the soil profile (m s-1)
 averageSoilEjection      => mvar_data%var(iLookMVAR%averageSoilEjection)%dat(1)      ! ejected water from the soil matrix (m s-1)
 averageAquiferRecharge   => mvar_data%var(iLookMVAR%averageAquiferRecharge)%dat(1)   ! recharge to the aquifer (m s-1)
 averageAquiferBaseflow   => mvar_data%var(iLookMVAR%averageAquiferBaseflow)%dat(1)   ! baseflow from the aquifer (m s-1)

 ! assign pointers to algorithmic control parameters
 minstep => mpar_data%var(iLookPARAM%minstep)  ! minimum time step (s)
 maxstep => mpar_data%var(iLookPARAM%maxstep)  ! maximum time step (s)
 !print*, 'minstep, maxstep = ', minstep, maxstep

 ! initialize average fluxes
 averageSurfaceRunoff     = 0._dp  ! surface runoff (m s-1)
 averageGroundEvaporation = 0._dp  ! ground evaporation/condensation - below canopy or non-vegetated (kg m-2 s-1)
 averageGroundSublimation = 0._dp  ! ground sublimation/frost - below canopy or non-vegetated (kg m-2 s-1)
 averageRainPlusMelt      = 0._dp  ! rain plus melt, as input to soil before calculating surface runoff (m s-1)
 averageSoilInflux        = 0._dp  ! influx of water at the top of the soil profile (m s-1)
 averageSoilBaseflow      = 0._dp  ! total baseflow from throughout the soil profile (m s-1)
 averageSoilDrainage      = 0._dp  ! drainage from the bottom of the soil profile (m s-1)
 averageSoilEjection      = 0._dp  ! ejected water from the soil matrix (m s-1)
 averageAquiferRecharge   = 0._dp  ! recharge to the aquifer (m s-1)
 averageAquiferBaseflow   = 0._dp  ! baseflow from the aquifer (m s-1)

 ! get the length of the time step (seconds)
 dt = forcFileInfo%data_step

 ! identify the maximum number of iterations
 select case(model_decisions(iLookDECISIONS%num_method)%iDecision)
  case(iterative);         maxiter=nint(mpar_data%var(iLookPARAM%maxiter))  ! iterative
  case(nonIterative);      maxiter=1              ! non-iterative
  case(iterSurfEnergyBal); maxiter=1              ! iterate only on the surface energy balance
   err=90; message=trim(message)//'numerical method "iterSurfEnergyBal" is not implemented yet'; return
  case default
   err=10; message=trim(message)//'unknown option for the numerical method'; return
 end select

 ! initialize the length of the sub-step
 dt_sub  = min(dt_init,dt)
 dt_done = 0._dp

 ! initialize the number of sub-steps
 nsub=0

 ! loop through sub-steps
 do  ! continuous do statement with exit clause (alternative to "while")

  ! increment the number of sub-steps
  nsub = nsub+1

  if(scalarSnowfall > 0._dp)then
   call newsnwfall(dt_sub,            & ! time step (seconds)
                   err,cmessage)        ! error control
   if(err/=0)then; err=55; message=trim(message)//trim(cmessage); return; endif
   !print*, 'scalarRainfall, scalarSnowfall = ', scalarRainfall, scalarSnowfall
   !stop ' snow is falling!'
  endif

  ! merge snow layers if they are too thin
  call layerMerge(err,cmessage)        ! error control
  if(err/=0)then; err=65; message=trim(message)//trim(cmessage); return; endif

  ! assign local pointers to the model index structures
  nSoil             => indx_data%var(iLookINDEX%nSoil)%dat(1)     ! number of soil layers
  nSnow             => indx_data%var(iLookINDEX%nSnow)%dat(1)     ! number of snow layers
  nLayers           => indx_data%var(iLookINDEX%nLayers)%dat(1)   ! total number of layers
  layerType         => indx_data%var(iLookINDEX%layerType)%dat    ! layer type (ix_soil or ix_snow)

  ! identify the number of snow and soil layers
  nSnow = count(layerType==ix_snow)
  nSoil = count(layerType==ix_soil)

  ! assign pointers to model state variables -- all layers
  mLayerTemp        => mvar_data%var(iLookMVAR%mLayerTemp)%dat                   ! temperature of each layer (K)
  mLayerDepth       => mvar_data%var(iLookMVAR%mLayerDepth)%dat                  ! depth of each layer (m)
  mLayerVolFracIce  => mvar_data%var(iLookMVAR%mLayerVolFracIce)%dat             ! volumetric fraction of ice in each layer (-)
  mLayerVolFracLiq  => mvar_data%var(iLookMVAR%mLayerVolFracLiq)%dat             ! volumetric fraction of liquid water in each layer (-)

  ! assign pointers to the model flux variables
  scalarGroundEvaporation => mvar_data%var(iLookMVAR%scalarGroundEvaporation)%dat(1) ! ground evaporation/condensation - below canopy or non-vegetated (kg m-2 s-1)
  scalarGroundSublimation => mvar_data%var(iLookMVAR%scalarGroundSublimation)%dat(1) ! ground sublimation/frost - below canopy or non-vegetated (kg m-2 s-1)
  scalarRainPlusMelt      => mvar_data%var(iLookMVAR%scalarRainPlusMelt)%dat(1)      ! rain plus melt, as input to soil before calculating surface runoff (m s-1)
  scalarSurfaceRunoff     => mvar_data%var(iLookMVAR%scalarSurfaceRunoff)%dat(1)     ! surface runoff (m s-1)
  scalarSoilInflux        => mvar_data%var(iLookMVAR%scalarSoilInflux)%dat(1)        ! influx of water at the top of the soil profile (m s-1)
  scalarSoilBaseflow      => mvar_data%var(iLookMVAR%scalarSoilBaseflow)%dat(1)      ! total baseflow from throughout the soil profile (m s-1)
  scalarSoilDrainage      => mvar_data%var(iLookMVAR%scalarSoilDrainage)%dat(1)      ! drainage from the bottom of the soil profile (m s-1)
  scalarSoilEjection      => mvar_data%var(iLookMVAR%scalarSoilEjection)%dat(1)      ! ejected water from the soil matrix (m s-1)
  scalarAquiferRecharge   => mvar_data%var(iLookMVAR%scalarAquiferRecharge)%dat(1)   ! recharge to the aquifer (m s-1)
  scalarAquiferBaseflow   => mvar_data%var(iLookMVAR%scalarAquiferBaseflow)%dat(1)   ! baseflow from the aquifer (m s-1)

  ! allocate temporary array
  allocate(arrTemp(nLayers),stat=err)
  if(err/=0)then; err=20; message='problem allocating space for temporary array'; return; endif

  ! save the volumetric fraction of ice
  arrTemp = mLayerDepth

  ! use Picard iteration to solve model equations
  do
   ! get the new solution
   call picardSolv(dt_sub,maxiter,(nsub==1),&  ! input
                   niter,err,cmessage)            ! output
   if(err>0)then; message=trim(message)//trim(cmessage); return; endif
   !if(err<0)then; print*, trim(message)//trim(cmessage); print*, 'dt_sub, minstep = ', dt_sub, minstep; pause; endif 
   ! exit do loop if all is a-ok
   if(err==0) exit
   ! if not ok, reduce time step and try again
   dt_sub = dt_sub*0.1_dp
   print*, dt_sub, minstep, trim(message)//trim(cmessage)
   !pause
   ! check that the step size is still appropriate -- if not, use non-iterative solution
   if(dt_sub < minstep)then
    if(err/=0)then; message=trim(message)//'dt_sub is below the minimum time step'; return; endif
    dt_sub  = minstep
    ! just iterate once
    call picardSolv(dt_sub,1,(nsub==1),&  ! input
                    niter,err,cmessage)   ! output
    if(err/=0)then; message=trim(message)//trim(cmessage); return; endif
    exit ! exit do loop if all is a-ok
   endif
  end do 

  ! define weight applied to each sub-step
  dt_wght = dt_sub/dt

  ! increment timestep-average fluxes
  averageGroundEvaporation = averageGroundEvaporation + scalarGroundEvaporation*dt_wght ! ground evaporation/condensation - below canopy or non-vegetated (kg m-2 s-1)
  averageGroundSublimation = averageGroundSublimation + scalarGroundSublimation*dt_wght ! ground sublimation/frost - below canopy or non-vegetated (kg m-2 s-1)
  averageRainPlusMelt      = averageRainPlusMelt      + scalarRainPlusMelt     *dt_wght ! rain plus melt, as input to soil before calculating surface runoff (m s-1)
  averageSurfaceRunoff     = averageSurfaceRunoff     + scalarSurfaceRunoff    *dt_wght ! surface runoff (m s-1)
  averageSoilInflux        = averageSoilInflux        + scalarSoilInflux       *dt_wght ! influx of water at the top of the soil profile (m s-1)
  averageSoilBaseflow      = averageSoilBaseflow      + scalarSoilBaseflow     *dt_wght ! total baseflow from throughout the soil profile (m s-1)
  averageSoilDrainage      = averageSoilDrainage      + scalarSoilDrainage     *dt_wght ! drainage from the bottom of the soil profile (m s-1)
  averageSoilEjection      = averageSoilEjection      + scalarSoilEjection     *dt_wght ! ejected water from the soil matrix (m s-1)
  averageAquiferRecharge   = averageAquiferRecharge   + scalarAquiferRecharge  *dt_wght ! recharge to the aquifer (m s-1)
  averageAquiferBaseflow   = averageAquiferBaseflow   + scalarAquiferBaseflow  *dt_wght ! recharge to the aquifer (m s-1)

  ! check that snow depth is decreasing (can only increase in the top layer)
  if(nSnow>1)then
   do iSnow=2,nSnow
    if(mLayerDepth(iSnow) > arrTemp(iSnow)+1.e-8_dp)then
     write(*,'(a,1x,100(f20.10))') 'depth1 = ', arrTemp(1:nSnow)
     write(*,'(a,1x,100(f20.10))') 'depth2 = ', mLayerDepth(1:nSnow)
     write(*,'(a,1x,100(f20.10))') 'diff   = ', mLayerDepth(1:nSnow) - arrTemp(1:nSnow)
     stop 'depth is increasing '
    endif
   end do ! looping thru snow layers
  endif

  ! increment the time step increment
  dt_done = dt_done + dt_sub
  !print*, '***** ', dt_done, dt_sub, niter

  ! modify the length of the time step
  if(niter<n_inc) dt_sub = dt_sub*F_inc
  if(niter>n_dec) dt_sub = dt_sub*F_dec

  ! save the time step to initialize the subsequent step
  if(dt_done<dt .or. nsub==1) dt_init = dt_sub
  if(dt_init < 0.001_dp .and. nsub > 100) then
   write(message,'(a,f13.10,a,f9.2,a,i0,a)')trim(message)//"dt < 0.001 and nsub > 100 [dt=",dt_init,"; dt_done=",&
         dt_done,"; nsub=",nsub,"]"
   err=20; return
  endif

  ! exit do-loop if finished
  if(dt_done>=dt)exit

  ! make sure that we don't exceed the step
  dt_sub = min(dt-dt_done, dt_sub)
  
  ! deallocate temporary array
  deallocate(arrTemp,stat=err)
  if(err/=0)then; err=20; message='problem deallocating space for temporary array'; return; endif

 end do  ! (sub-step loop)

 ! perform the routing
 call qOverland(&
                ! input
                model_decisions(iLookDECISIONS%subRouting)%iDecision, &  ! index for routing method
                averageSurfaceRunoff,                                 &  ! surface runoff (m s-1)
                averageSoilEjection,                                  &  ! ejected water from the soil profile (m s-1)
                averageSoilBaseflow,                                  &  ! baseflow from the soil profile (m s-1)
                averageAquiferBaseflow,                               &  ! baseflow from the aquifer (m s-1)
                mvar_data%var(iLookMVAR%routingFractionFuture)%dat,   &  ! fraction of runoff in future time steps (m s-1)
                mvar_data%var(iLookMVAR%routingRunoffFuture)%dat,     &  ! runoff in future time steps (m s-1)
                ! output
                mvar_data%var(iLookMVAR%averageInstantRunoff)%dat(1), &  ! instantaneous runoff (m s-1)
                mvar_data%var(iLookMVAR%averageRoutedRunoff)%dat(1),  &  ! routed runoff (m s-1)
                err,cmessage)                                            ! error control
 if(err/=0)then; message=trim(message)//trim(cmessage); return; endif

 ! save the surface temperature (just to make things easier to visualize)
 !mvar_data%var(iLookMVAR%scalarSurfaceTemp)%dat(1) = mvar_data%var(iLookMVAR%mLayerTemp)%dat(1)

 iLayer = nSnow+1
 !print*, 'nsub, mLayerTemp(iLayer), mLayerVolFracIce(iLayer) = ', nsub, mLayerTemp(iLayer), mLayerVolFracIce(iLayer)
 print*, 'nsub = ', nsub
 if(nsub>1000)then
  message=trim(message)//'number of sub-steps > 1000'
  err=20; return
 endif

 !write(*,'(a)') '==========================================================================================================================='
 !write(*,'(a)') '==========================================================================================================================='
 !write(*,'(a)') '==========================================================================================================================='
 !write(*,'(a)') '==========================================================================================================================='
 !write(*,'(a)') '==========================================================================================================================='

 
 if(mLayerVolFracIce(iLayer) > 0.5_dp) pause 'ice content in top soil layer is huge...'
 
 end subroutine coupled_em

end module coupled_em_module

!
!   @File:    ObserverClass.f90
!   @Author:  Oscar Marino (oscar.marino@upm.es)
!   @Created: Mar 22 2020
!   @Last revision date: 
!   @Last revision author: 
!   @Last revision commit: 
!
!//////////////////////////////////////////////////////
!
!This class represents the observer for the fW-H accoustic analogy, including the relations with several observers

#include "Includes.h"
Module  FWHObseverClass  !

   use SMConstants
   use FaceClass
   use Physics
   use PhysicsStorage
   use NodalStorageClass
   use FWHDefinitions, only: OB_BUFFER_SIZE, OB_BUFFER_SIZE_DEFAULT, STR_LEN_OBSERVER
   use ZoneClass
   use HexMeshClass
   use MPI_Process_Info
#ifdef _HAS_MPI_
   use mpi
#endif
   Implicit None

!
!  *****************************
!  Observer source pair class definition
!  class for the coupling of each pair of observer and source(face)
!  mainly accoustic geometrical relations and face link
!  *****************************
   type ObserverSourcePairClass
       real(kind=RP), dimension(:,:,:), allocatable        :: rVect
       real(kind=RP), dimension(:,:),   allocatable        :: r
       real(kind=RP), dimension(:,:),   allocatable        :: re
       real(kind=RP), dimension(:,:,:), allocatable        :: reUnitVect 
       real(kind=RP), dimension(:,:),   allocatable        :: reStar
       real(kind=RP), dimension(:,:,:), allocatable        :: reStarUnitVect 
       real(kind=RP)                                       :: tDelay
       integer                                             :: faceIDinMesh    ! ID of the source (face) at the Mesh array (linked list)
       real(kind=RP)                                       :: normalCorrection
       real(kind=RP), dimension(:,:),   allocatable        :: Pacc ! temporal solution of accoustic pressure for each pair
       real(kind=RP), dimension(:),     allocatable        :: tInterp ! time array for interpolation

       contains

           procedure :: construct       => ObserverSourcePairConstruct
           procedure :: destruct        => ObserverSourcePairDestruct
           procedure :: allocPacc       => ObserverSourcePairAllocSolution
           procedure :: interpolateSolF => ObserverSourcePairInterpolateSolFirst
           procedure :: newUpdate       => ObserverSourcePairNewUpdate
           procedure :: interpolateSolS => ObserverSourcePairInterpolateSolSecond
           procedure :: updateOneStep   => ObserverSourcePairUpdateOneStep
           procedure :: FWHSurfaceIntegral

   end type ObserverSourcePairClass
!
!  *****************************
!  General observer class definition
!   (similar to a monitor, mostly surface monitor in many behaviours)
!  *****************************
!  
   type ObserverClass

       integer                                                         :: ID
       real(kind=RP), dimension(NDIM)                                  :: x        ! position of the observer at global coordinates
       integer                                                         :: numberOfFaces
       class(ObserverSourcePairClass), dimension(:), allocatable       :: sourcePair
       real(kind=RP), dimension(:,:), allocatable                      :: Pac      ! accoustic pressure, two componenets and the total (sum)
       real(kind=RP)                                                   :: tDelay
       real(kind=RP)                                                   :: tDelayMax
       logical                                                         :: active
       character(len=STR_LEN_OBSERVER)                                 :: observerName
       character(len=STR_LEN_OBSERVER)                                 :: fileName

       contains

           procedure :: construct      => ObserverConstruct
           procedure :: destruct       => ObserverDestruct
           procedure :: update         => ObserverUpdate
           procedure :: writeToFile    => ObserverWriteToFile
           procedure :: updateTdelay   => ObserverUpdateTdelay
           procedure :: interpolateSol => ObserverInterpolateSol
           procedure :: sumIntegrals   => ObserverSumIntegrals
           procedure :: updateOneStep  => ObserverUpdateOneStep

   end type ObserverClass

   contains

!/////////////////////////////////////////////////////////////////////////
!           OBSERVER CLASS PROCEDURES --------------------------
!/////////////////////////////////////////////////////////////////////////

   Subroutine ObserverConstruct(self, sourceZone, mesh, ID, solution_file, FirstCall, interpolate, totalNumberOfFaces, eIDs)

!        *****************************************************************************
!              This subroutine initializes the observer similar to a monitor. The following
!           data is obtained from the case file:
!              -> Name: The observer name (10 characters maximum)
!              -> x: The observer position
!        *****************************************************************************

       use ParamfileRegions
       use FileReadingUtilities, only: getRealArrayFromString
       implicit none

       class(ObserverClass)                                 :: self
       class(Zone_t), intent(in)                            :: sourceZone
       class(HexMesh), intent(in)                           :: mesh
       integer, intent(in)                                  :: ID, totalNumberOfFaces
       character(len=*), intent(in)                         :: solution_file
       logical, intent(in)                                  :: FirstCall, interpolate
       integer, dimension(:), intent(in)                    :: eIDs

       ! local variables
       character(len=STR_LEN_OBSERVER)  :: in_label
       character(len=STR_LEN_OBSERVER)  :: fileName
       character(len=STR_LEN_OBSERVER)  :: paramFile
       character(len=STR_LEN_OBSERVER)  :: coordinates
       integer                          :: fID
       integer                          :: MeshFaceID, zoneFaceID
       integer                          :: elementSide
!
!      Get observer ID
!      --------------
       self % ID = ID
!
!      Search for the parameters in the case file
!      ------------------------------------------
       write(in_label , '(A,I0)') "#define accoustic observer " , self % ID

       call get_command_argument(1, paramFile)
       call readValueInRegion(trim ( paramFile), "name",   self % observerName, in_label, "# end" ) 
       call readValueInRegion(trim(paramFile), "position", coordinates        , in_label, "# end" )

!      Get the coordinates
!      -------------------
       self % x = getRealArrayFromString(coordinates)

!     Enable the observer
!     ------------------
      self % active = .true.
      allocate ( self % Pac(OB_BUFFER_SIZE,3) )

      !     ------------------
!     Get source information
      self % numberOfFaces = sourceZone % no_of_faces

!     Construct each pair observer-source
!     ------------------
      allocate( self % sourcePair(self % numberOfFaces) )
!     Loop the zone to get faces
      elementSide = 0
      do zoneFaceID = 1, self % numberOfFaces
!         Face global ID
          MeshFaceID = sourceZone % faces(zoneFaceID)
          ! boundary case
          if (all(eIDs .eq. 0)) then
              elementSide = 1
          else
              ! get from side that correspond to the element in file

              ! if findloc is suport by the compiler use this line and comment the if
              ! elementSide = findloc(mesh%faces(MeshFaceID)%elementIDs, eIDs(zoneFaceID), dim=1)
              if ( mesh%faces(MeshFaceID)%elementIDs(1) .eq. eIDs(zoneFaceID) ) then
                  elementSide = 1
              elseif ( mesh%faces(MeshFaceID)%elementIDs(2) .eq. eIDs(zoneFaceID) ) then
                  elementSide = 2
              end if 
              if (elementSide .eq. 0) then
                  print *, "Error: the element ", eIDs(zoneFaceID), " does not correspond to the face ", mesh % faces(MeshFaceID) % ID, &
                      ". The elements of the face are: " , mesh%faces(MeshFaceID)%elementIDs, ". The faces of the elemet are: ", mesh%elements(eIDs(zoneFaceID))%faceIDs
                  call exit(99)
              end if 
          end if 
          call self % sourcePair(zoneFaceID) % construct(self % x, mesh % faces(MeshFaceID), MeshFaceID, FirstCall, elementSide)
      end do  

!     Allocate variables for interpolation
!     -------------------------------------------------
      if (interpolate) then
          do zoneFaceID = 1, self % numberOfFaces
              call self % sourcePair(zoneFaceID) % allocPacc(OB_BUFFER_SIZE)
          end do
      end if 

!     Set the average time delay of the observer
!     -------------------------------------------------
      call self % updateTdelay(totalNumberOfFaces)

!     Prepare the file in which the observer is exported
!     -------------------------------------------------
      write( self % fileName , '(A,A,A,A)') trim(solution_file) , "." , trim(self % observerName) , ".observer"
!
!     Create file
!     -----------
      if (FirstCall) then
         open ( newunit = fID , file = trim(self % fileName) , status = "unknown" , action = "write" ) 

!        Write the file headers
!        ----------------------
         write( fID , '(A20,A  )') "Observer name:      ", trim(self % observerName)
         write( fID , '(A20,ES24.10)') "x coordinate: ", self % x(1)
         write( fID , '(A20,ES24.10)') "y coordinate: ", self % x(2)
         write( fID , '(A20,ES24.10)') "z coordinate: ", self % x(3)

         write( fID , * )
         write( fID , '(A10,5(2X,A24))' ) "Iteration" , "Time" , "Observer_Time", "P'T", "P'L", "P'"

         close ( fID )
      end if

   End Subroutine ObserverConstruct

   Subroutine ObserverUpdate(self, mesh, isSolid, BufferPosition, interpolate)

!     *******************************************************************
!        This subroutine updates the observer accoustic pressure computing it from
!        the mesh storage. It is stored in the "bufferPosition" position of the 
!        buffer.
!     *******************************************************************
!
use VariableConversion, only: Pressure, PressureDot
      implicit none
      class (ObserverClass)                                :: self
      class (HexMesh), intent(in)                          :: mesh
      integer,intent(in), optional                         :: bufferPosition
      logical, intent(in)                                  :: isSolid, interpolate

      ! local variables
      real(kind=RP)                                        :: Pt, Pl  ! pressure of each pair
      real(kind=RP), dimension(3)                          :: localPacc, Pacc   ! temporal variable to store the sum of the pressure
      real(kind=RP), dimension(3)                          :: mInterp ! slope of interpolation
      real(kind=RP)                                        :: valx, valy, valz
      integer                                              :: zoneFaceID, meshFaceID,  ierr
      integer                                             :: storePosition

!     Initialization
!     --------------            
      if (present(bufferPosition)) self % Pac(bufferPosition,:) = 0.0_RP
      Pacc = 0.0_RP
      valx = 0.0_RP
      valy = 0.0_RP
      valz = 0.0_RP

!     Loop the pairs (equivalent to loop the zone) and get the values
!     ---------------------------------------
      interp_cond: if (interpolate) then
!        For this case only save the values of the solution of each pair, at the corresponding position
!        ---------------------------------------
!$omp parallel private(meshFaceID,storePosition,localPacc) shared(mesh,isSolid,interpolate,Pacc,NodalStorage,&
!$omp&                                                     self,bufferPosition)
!$omp do private(meshFaceID,storePosition,localPacc) schedule(runtime)
         do zoneFaceID = 1, self % numberOfFaces
!            Compute the integral
!            --------------------
             meshFaceID = self % sourcePair(zoneFaceID) % faceIDinMesh
             localPacc = self % sourcePair(zoneFaceID) % FWHSurfaceIntegral( mesh % faces(meshFaceID), isSolid )

             !save solution at bufferPosition or last position
             if (present(bufferPosition)) then
                 storePosition = bufferPosition
             else
                 storePosition = size(self % sourcePair(zoneFaceID) % Pacc, dim=1)
             end if
             self % sourcePair(zoneFaceID) % Pacc(storePosition,:) = localPacc
         end do  
!$omp end do
!$omp end parallel
     else interp_cond
!        For this case get the whole solution of the observer, adding all the pairs without saving
!        ---------------------------------------
!$omp parallel private(meshFaceID, localPacc) shared(mesh,isSolid,interpolate,Pacc,NodalStorage,&
!$omp&                                        self,valx,valy,valz)
!$omp do private(meshFaceID,localPacc) reduction(+:valx,valy,valz) schedule(runtime)
          do zoneFaceID = 1, self % numberOfFaces
!            Compute the integral
!            --------------------
             meshFaceID = self % sourcePair(zoneFaceID) % faceIDinMesh

             localPacc = self % sourcePair(zoneFaceID) % FWHSurfaceIntegral( mesh % faces(meshFaceID), isSolid )

             ! sum without interpolate: supose little change of each tDelay
             valx = valx + localPacc(1)
             valy = valy + localPacc(2)
             valz = valz + localPacc(3)
         end do  
!$omp end do
!$omp end parallel

          Pacc = (/valx, valy, valz/)

#ifdef _HAS_MPI_
      localPacc = Pacc
      call mpi_allreduce(localPacc, Pacc, 3, MPI_DOUBLE, MPI_SUM, MPI_COMM_WORLD, ierr)
#endif

          self % Pac(bufferPosition,:) = Pacc
     end if interp_cond

   End Subroutine ObserverUpdate

   Subroutine ObserverUpdateTdelay(self, totalNumberOfFaces)

!     *******************************************************************
!        This subroutine updates the observer time delay. For static surfaces it 
!        doesn't need to be updated at every iteration.
!        Minimum time is used, for interpolation procedures
!     *******************************************************************
!
      use MPI_Process_Info
      implicit none
      class   (ObserverClass)                              :: self
      integer, intent(in)                                  :: totalNumberOfFaces
      
      ! local variables
      integer                                              :: i, ierr
      real(kind=RP)                                        :: t, tmax
      real(kind=RP), dimension(:), allocatable             :: alltDelay
      real(kind=RP), dimension(self % numberOfFaces)       :: tDelayArray
      integer, dimension(MPI_Process % nProcs)             :: no_of_faces_p, displs

      do i =1, self % numberOfFaces
        tDelayArray(i) = self % sourcePair(i) % tDelay
      end do

      if ( (MPI_Process % doMPIAction) ) then
#ifdef _HAS_MPI_
          call mpi_gather(self % numberOfFaces,1,MPI_INT,no_of_faces_p,1,MPI_INT,0,MPI_COMM_WORLD,ierr)

          if (MPI_Process % isRoot) then
              displs=0
              do i = 2, MPI_Process % nProcs 
                  displs(i) = displs(i-1) + no_of_faces_p(i-1)
              end do
          end if

          allocate(alltDelay(totalNumberOfFaces))
          call mpi_gatherv(tDelayArray, self % numberOfFaces, MPI_DOUBLE, &
                                     alltDelay, no_of_faces_p, displs, MPI_DOUBLE, 0, MPI_COMM_WORLD, ierr)

          if (MPI_Process % isRoot) then
              t = minval(alltDelay)
              tmax = maxval(alltDelay)
          end if

          call mpi_Bcast(t, 1, MPI_DOUBLE, 0, MPI_COMM_WORLD, ierr)
          call mpi_Bcast(tmax, 1, MPI_DOUBLE, 0, MPI_COMM_WORLD, ierr)
#endif
      else
          t = minval(tDelayArray)
          tmax = maxval(tDelayArray)
      end if

      self % tDelay = t
      self % tDelayMax = tmax

   End Subroutine ObserverUpdateTdelay

   Subroutine ObserverWriteToFile(self, iter, tsource, no_of_lines)
!
!     *************************************************************
!           This subroutine writes the buffer to the file.
!     *************************************************************
!
      implicit none  
      class(ObserverClass)                                 :: self
      integer, dimension(:)                                :: iter
      real(kind=RP), dimension(:)                          :: tsource
      integer                                              :: no_of_lines
!
!     ---------------
!     Local variables
!     ---------------
!
      integer                    :: i
      integer                    :: fID

      if ( MPI_Process % isRoot ) then

         open( newunit = fID , file = trim ( self % fileName ) , action = "write" , access = "append" , status = "old" )
      
         do i = 1 , no_of_lines
            write( fID , '(I10,5(2X,ES24.16))' ) iter(i) , tsource(i), tsource(i) + self % tDelay, self % Pac(i,:)
         end do
      
         close ( fID )
      end if
      
      if ( no_of_lines .ne. 0 ) self % Pac(1,:) = self % Pac(no_of_lines,:)
      
   End Subroutine ObserverWriteToFile

    Subroutine ObserverUpdateOneStep(self, mesh, BufferPosition, isSolid, tsource)

      implicit none

      class (ObserverClass)                                :: self
      class (HexMesh), intent(in)                          :: mesh
      integer,intent(in)                                   :: bufferPosition
      logical, intent(in)                                  :: isSolid
      real(kind=RP), intent(in)                            :: tsource

      ! local variables
      real(kind=RP)                                        :: tobserver
      integer                                              :: i
      integer, dimension(self%numberOfFaces)               :: nDiscard

      ! store the solution of each pair at the last position, by not giving the bufferPosition
      call self % update(mesh, isSolid, interpolate=.TRUE.)

      ! interpolate the solution of each pair at first position
      ! and save the time of each pair at its last position
      tobserver = tsource + self % tDelay
!$omp parallel shared(self)
!$omp do schedule(runtime)
      do i = 1, self % numberOfFaces
            if (self % sourcePair(i) % tDelay .eq. self % tDelay) cycle
            call self % sourcePair(i) % interpolateSolS(tobserver, tsource)
      end do 
!$omp end do
!$omp end parallel

      ! sum all the pair solution and save it at bufferPosition of the observer sol
      nDiscard = 0
      call self % sumIntegrals(nDiscard, 1, bufferPosition, bufferPosition)

      ! update the solution of each pair and its times for next iteration
!$omp parallel shared(self)
!$omp do schedule(runtime)
      do i = 1, self % numberOfFaces
            call self % sourcePair(i) % updateOneStep()
      end do 
!$omp end do
!$omp end parallel

    End Subroutine ObserverUpdateOneStep

   !interpolate the solution of all the pairs to get it at the mean observer time
   Subroutine ObserverInterpolateSol(self, tsource, no_of_lines)

      implicit none  

      class(ObserverClass)                                 :: self
      real(kind=RP), dimension(:), intent(in)              :: tsource
      integer, intent(in)                                  :: no_of_lines

      !local variables
      real(kind=RP), dimension(:), allocatable             :: tobserver
      integer                                              :: i, n, k, m
      integer, dimension(self % numberOfFaces)             :: nDiscard
      logical                                              :: sameDelay

      allocate(tobserver(no_of_lines))
      tobserver = tsource(1:no_of_lines) + self % tdelay

      ! get max tobserver that can be interpolated
      do k =1, no_of_lines
          if ( tobserver(k) .ge. (self % tDelayMax + tsource(1)) ) exit
      end do
      n = no_of_lines - k + 1 ! k is the min tobserver index

      safedeallocate(tobserver)
      allocate(tobserver(n))
      tobserver(1:n) = tsource(k:no_of_lines) + self % tdelay

!$omp parallel shared(self, nDiscard, n, no_of_lines, tobserver, tsource,k)
!$omp do schedule(runtime)
      do i = 1, self % numberOfFaces
          ! call interp of each pair that are not the minimum
          ! if (almostequal(self % sourcepair(i) % tdelay, self % tdelay)) then
          if (self % sourcepair(i) % tdelay .eq. self % tdelay) then
              nDiscard(i) = k-1
          else
              call self % sourcePair(i) % interpolateSolF(n, no_of_lines, tobserver, tsource(1:no_of_lines), nDiscard(i))
          end if
      end do
!$omp end do
!$omp end parallel

      ! set to 0 the first part of the solution, which cannot be interpolated
      ! in this case Pacc is written from 1:no_of_lines, which have a value of 0 at first positions, not need to change obs write proc
      self % pac(1:k-1,:) = 0.0_RP

      ! sum all values from k to no_of_lines
      call self % sumIntegrals(nDiscard, n, k, no_of_lines)

      ! update all the solution of the pair to save the future ones
      do i = 1, self % numberOfFaces
          ! sameDelay = almostequal(self % sourcepair(i) % tdelay, self % tdelay)
          sameDelay = self % sourcepair(i) % tdelay .eq. self % tdelay
          call self % sourcePair(i) % newUpdate(n, nDiscard(i), no_of_lines, tsource(1:no_of_lines), sameDelay)
      end do

   End Subroutine ObserverInterpolateSol

   ! sum all the interpolated solution of all pairs and save it at the observer solution
   Subroutine ObserverSumIntegrals(self, nDiscard, N, startIndex, no_of_lines)

      implicit none  

      class(observerclass)                                 :: self
      integer, intent(in)                                  :: no_of_lines, startIndex, N
      integer, dimension(self % numberOfFaces), intent(in) :: nDiscard

      ! local variables
      real(kind=RP), dimension(:,:), allocatable           :: localPacc, Pacc   ! temporal variable to store the sum of the pressure
      real(kind=RP), dimension(:), allocatable             :: valx, valy, valz
      integer                                              :: i, ierr

!     Initialization
!     --------------            
      ! 1:N must be equal to startIndex:no_of_lines
      allocate(Pacc(N,3), localPacc(N,3), valx(N), valy(N), valz(N))
      Pacc = 0.0_RP
      valx = 0.0_RP
      valy = 0.0_RP
      valz = 0.0_RP

!$omp parallel private(localPacc) shared(Pacc,nDiscard,N,self,valx,valy,valz)
!$omp do private(localPacc) reduction(+:valx,valy,valz) schedule(runtime)
      do i = 1, self % numberOfFaces
!        Get the array of interpolated values of each pair
         localPacc(1:N,:) = self % sourcePair(i) % Pacc(nDiscard(i)+1:nDiscard(i)+N,:)

         ! sum interpolated
         valx = valx + localPacc(:,1)
         valy = valy + localPacc(:,2)
         valz = valz + localPacc(:,3)

      end do  
!$omp end do
!$omp end parallel

      Pacc(:,1) = valx(:)
      Pacc(:,2) = valy(:)
      Pacc(:,3) = valz(:)

#ifdef _HAS_MPI_
      localPacc = Pacc
      call mpi_allreduce(localPacc, Pacc, 3*N, MPI_DOUBLE, MPI_SUM, MPI_COMM_WORLD, ierr)
#endif

      self % Pac(startIndex:no_of_lines,:) = Pacc(1:N,:)

   End Subroutine ObserverSumIntegrals

   Subroutine ObserverDestruct(self)

        implicit none
        class(ObserverClass), intent(inout)               :: self

       ! local variables
       integer                                            :: i
        safedeallocate (self % Pac)
        do i = 1, self % numberOfFaces
            call self % sourcePair(i) % destruct
        end do
        safedeallocate (self % sourcePair)

   End Subroutine ObserverDestruct

!/////////////////////////////////////////////////////////////////////////
!           OBSERVER SOURCE PAIR CLASS PROCEDURES --------------------------
!/////////////////////////////////////////////////////////////////////////

   Subroutine  ObserverSourcePairConstruct(self, x, f, fID, FirstCall, elementSide)

       ! use fluiddata
       use FWHDefinitions, only: rho0, P0, c0, U0, M0, fwGamma2
       implicit none

       class(ObserverSourcePairClass)                      :: self
       real(kind=RP), dimension(NDIM), intent(in)          :: x       ! observer position
       type(face), intent(in)                              :: f    ! source
       integer, intent(in)                                 :: fID, elementSide
       logical, intent(in)                                 :: FirstCall

       ! local variables
       integer                                             :: Nx,Ny
       integer                                             :: i, j
       real(kind=RP)                                       :: fwGammaInv

       self % faceIDinMesh = fID

       Nx = f % Nf(1)
       Ny = f % Nf(2)

   select case (elementSide)
   case (1)
       self % normalCorrection = 1.0_RP
   case (2)
       self % normalCorrection = -1.0_RP
   end select

       allocate( self % r(0:Nx,0:Ny), self % re(0:Nx,0:Ny), self % reStar(0:Nx,0:Ny) )
       allocate( self % rVect(NDIM,0:Nx,0:Ny), self % reUnitVect(NDIM,0:Nx,0:Ny) ,self % reStarUnitVect(NDIM,0:Nx,0:Ny) )

       fwGammaInv = 1.0_RP / sqrt(fwGamma2)
       ! source position, for each node of the face
       associate (y => f % geom % x)
           do j= 0, Ny; do i = 0,Nx
           ! if ( .eq. 374 ) then
               ! store geometrical accoustic relations for each node
               self % rVect(:,i,j) = x(:) - y(:,i,j)
               self % r(i,j) = norm2(self % rVect(:,i,j))
               self % reStar(i,j) = fwGammaInv*sqrt( self%r(i,j)**2 + fwGamma2*( dot_product(M0, self%rVect(:,i,j)) )**2 )
               self % reStarUnitVect(:,i,j) = ( self%rVect(:,i,j) + fwGamma2*dot_product(M0, self%rVect(:,i,j))*M0(:) ) / &
                                            (fwGamma2*self%reStar(i,j))
               self % re(i,j) = fwGamma2*( self%reStar(i,j) - dot_product(M0, self%rVect(:,i,j)) )
               self % reUnitVect(:,i,j) = fwGamma2*( self%reStarUnitVect(:,i,j) - M0(:) )
               self % tDelay = (sum(self%re))/real(size(self%re),RP) / c0
           end do; end do
       end associate

   End Subroutine ObserverSourcePairConstruct 

  elemental Subroutine ObserverSourcePairDestruct(self)

      Class(ObserverSourcePairClass), intent(inout)       :: self
 
      safedeallocate(self % rVect)
      safedeallocate(self % r)
      safedeallocate(self % re)
      safedeallocate(self % reUnitVect)
      safedeallocate(self % reStar)
      safedeallocate(self % reStarUnitVect)

  End Subroutine ObserverSourcePairDestruct 

  ! allocate time history solution for a posterior interpolation

  Subroutine ObserverSourcePairAllocSolution(self, buffer_size)

       class(ObserverSourcePairClass)                      :: self
       integer, intent(in)                                 :: buffer_size
       
       allocate(self % Pacc(buffer_size,3))

  End Subroutine ObserverSourcePairAllocSolution

  Subroutine ObserverSourcePairInterpolateSolFirst(self, N, M, tobserver, tsource, nd)

       implicit none

       class(ObserverSourcePairClass)                      :: self
       integer, intent(in)                                 :: N, M
       real(kind=RP), dimension(N), intent(in)             :: tobserver
       real(kind=RP), dimension(:), intent(in)             :: tsource
       integer, intent(out)                                :: nd

       ! local variables
       real(kind=RP), dimension(N,3)                       :: PaccInterp    ! solution of the pair interpolated
       real(kind=RP), dimension(M)                         :: tPair         ! time array of the panel
       integer                                             :: i, j, ii

       ! get the times of the pair for interpolation
       tPair = tsource + self % tDelay

       j = 1
       nd = 0
       do i = 2, M
           if (j .gt. N) exit
           ii = i - 1
           if (tPair(i) .lt. tobserver(1)) then
               nd = nd +1
               cycle
           end if 
           PaccInterp(j,:) = linearInterpolation(tobserver(j), tPair(ii), self%Pacc(ii,:), tPair(i), self%Pacc(i,:), 3)
           j = j + 1
       end do 

           !update solution of the pair with the interpolated one
           self % Pacc(nd+1:nd+N,:) = PaccInterp

  End Subroutine ObserverSourcePairInterpolateSolFirst

  Subroutine ObserverSourcePairNewUpdate(self, N, NDiscard, M, tsource, sameDelay)

       implicit none

       class(ObserverSourcePairClass)                      :: self
       integer, intent(in)                                 :: N, NDiscard, M
       ! real(kind=RP), dimension(N), intent(in)             :: tobserver
       real(kind=RP), dimension(:), intent(in)             :: tsource
       logical, intent(in)                                 :: sameDelay

       !local variables
       real(kind=RP), dimension(M)                         :: tPair         ! time array of the panel
       real(kind=RP), dimension(:,:), allocatable          :: PaccFuture    ! solution of the pair of future (have not been interpolainterpolated) values
       integer                                             :: Nfuture

       tPair = tsource + self % tDelay
       if (sameDelay) then
           !size = 1 for last value + 1(empty for next iter)
           Nfuture = 2
       else
           !size = M - interpolated values +1 + 1(empty for next iter)
           Nfuture = M - N -NDiscard + 1
       end if 

       ! save old results and kept last position empty
       allocate(PaccFuture(Nfuture-1,3))
       PaccFuture(:,:) = self % Pacc(M-Nfuture+2:M,:)

       safedeallocate(self % Pacc)
       allocate(self % Pacc(1:Nfuture,3))

       self % Pacc(1:Nfuture-1,:) = PaccFuture(:,:)

       if (.not. sameDelay) then
           allocate(self % tInterp(1:Nfuture))
           ! save old results and kept last position empty
           self % tInterp(1:Nfuture-1) = tPair(NDiscard+N+1:M)
       end if 

  End Subroutine ObserverSourcePairNewUpdate

  ! save the solution and times from position 2 to last as the first position, letting free the last one
  Subroutine ObserverSourcePairUpdateOneStep(self)

      implicit none
      class(ObserverSourcePairClass)                      :: self

      !local variables
      integer                                             :: M

      M = size(self%Pacc, dim=1)
      if (allocated(self%tInterp)) self % tInterp(1:M-1) = self % tInterp(2:M)
      self % Pacc(1:M-1,:) = self % Pacc(2:M,:)

  End Subroutine ObserverSourcePairUpdateOneStep

  Subroutine ObserverSourcePairInterpolateSolSecond(self, tobserver, tsource)

       implicit none

       class(ObserverSourcePairClass)                      :: self
       real(kind=RP),  intent(in)                          :: tobserver
       real(kind=RP),  intent(in)                          :: tsource

       ! local variables
       real(kind=RP), dimension(2)                         :: tPair         ! time array of the panel
       real(kind=RP), dimension(3)                         :: PaccInterp    ! solution of the pair interpolated

       ! save last time
       self % tInterp(size(self % tInterp)) = tsource + self % tDelay
       ! use 2 first values to interpolate
       tPair = self % tInterp(1:2)

       PaccInterp(:) = linearInterpolation(tobserver, tPair(1), self % Pacc(1,:), tPair(2), self % Pacc(2,:), 3)

       !update the first value of the solution of the pair with the interpolated one
       self % Pacc(1,:) = PaccInterp(:)

    End Subroutine ObserverSourcePairInterpolateSolSecond

   ! calculate the surface integrals of the FW-H analogy for stacionary surfaces (permable or impermeable) with a general flow
   ! direction of the medium
   ! the integrals are for a single face (pane in FWH terminology) for a single observer
!         TODO: check if is more efficient to store FWHvariables for each face instead of calculating it always
!               for many observers, its being recomputed as many as observers

   ! Function FWHSurfaceIntegral(self, f, isSolid, interpolate, bufferPosition) result(Pacc)
   Function FWHSurfaceIntegral(self, f, isSolid) result(Pacc)

       use FWHDefinitions, only: rho0, P0, c0, U0, M0
       use VariableConversion, only: Pressure, PressureDot
       use fluiddata, only: dimensionless
       implicit none

       class(ObserverSourcePairClass)                      :: self
       class(Face), intent(in)                             :: f
       logical, intent(in)                                 :: isSolid
       real(kind=RP),dimension(3)                          :: Pacc  ! accoustic pressure values
       ! logical, intent(in)                                 :: isSolid, interpolate
       ! integer, intent(in), optional                       :: bufferPosition

       ! local variables
       integer                                             :: i, j  ! face indexes
       real(kind=RP), dimension(NDIM)                      :: Qi,QiDot, n
       real(kind=RP), dimension(NDIM,NDIM)                 :: Lij, LijDot
       type(NodalStorage_t), pointer                       :: spAxi, spAeta
       real(kind=RP)                                       :: Pt, Pl
       real(kind=RP)                                       :: LR, MR, UmMr,LdotR, LM
       ! integer                                             :: storePosition

       ! Initialization
       Pt = 0.0_RP
       Pl = 0.0_RP
       spAxi  => NodalStorage(f % Nf(1))
       spAeta => NodalStorage(f % Nf(2))


       associate( Q => f % storage(1) % Q )
           associate( Qdot => f % storage(1) % Qdot )

    !           **********************************
    !           Computes the surface integral
    !              I = \int vec{f}·vec{n} * vec{g}·vec{r} dS
    !           **********************************
    !
                do j = 0, f % Nf(2) ;    do i = 0, f % Nf(1)

                   n = f % geom % normal(:,i,j) * self % normalCorrection
                   call calculateFWHVariables(Q(:,i,j), Qdot(:,i,j), isSolid, Qi, QiDot, Lij, LijDot)

                   LR = dot_product(matmul(Lij, n(:)), self%reUnitVect(:,i,j))
                   MR = dot_product(M0(:), self % reUnitVect(:,i,j))
                   UmMr = 1 - MR
                   LdotR = dot_product(matmul(LijDot, n(:)), self%reUnitVect(:,i,j))
                   LM = dot_product(matmul(Lij, n(:)), M0(:))

                   ! loading term integrals
                   Pl = Pl +  dot_product(matmul(LijDot,n(:)),self%reUnitVect(:,i,j)) / (self%reStar(i,j) * c0) * &
                             spAxi % w(i) * spAeta % w(j) * f % geom % jacobian(i,j)
                   Pl = Pl +  dot_product(matmul(Lij,n(:)),self%reStarUnitVect(:,i,j)) / (self%reStar(i,j)**2) * &
                             spAxi % w(i) * spAeta % w(j) * f % geom % jacobian(i,j)
                   ! Pl = Pl + LdotR / ( c0 * self % re(i,j) * (UmMr**2) ) * &
                   !           spAxi % w(i) * spAeta % w(j) * f % geom % jacobian(i,j)
                   ! Pl = Pl + (LR - LM) / ( (self % re(i,j) * UmMr)**2 ) * &
                   !           spAxi % w(i) * spAeta % w(j) * f % geom % jacobian(i,j)
                   ! Pl = Pl + (LR * (MR - (dimensionless % Mach**2))) / ( (self % re(i,j)**2) * (UmMr**3) ) * &
                   !           spAxi % w(i) * spAeta % w(j) * f % geom % jacobian(i,j)

                   ! thickness term integrals, only for permable surfaces
                   if (.not. isSolid) then
                       Pt = Pt + (1 - dot_product(M0(:),self%reUnitVect(:,i,j))) * dot_product(QiDot(:),n(:)) / (self%reStar(i,j)) * &
                                 spAxi % w(i) * spAeta % w(j) * f % geom % jacobian(i,j)
                       Pt = Pt -  dot_product(U0(:),self%reStarUnitVect(:,i,j)) * dot_product(Qi(:),n(:)) / (self%reStar(i,j)**2) * &
                                 spAxi % w(i) * spAeta % w(j) * f % geom % jacobian(i,j)
                       ! Pt = Pt + dot_product(QiDot(:),n(:)) / (self%reStar(i,j) * (UmMr**2)) * &
                       !           spAxi % w(i) * spAeta % w(j) * f % geom % jacobian(i,j)
                       ! Pt = Pt + (dot_product(Qi(:), n(:)) * c0 * (MR - (dimensionless % Mach**2))) / ( (self % re(i,j)**2) * (UmMr**3) ) * &
                       !           spAxi % w(i) * spAeta % w(j) * f % geom % jacobian(i,j)

                   end if  
                end do          ;    end do
           end associate
       end associate

       Pt = Pt / (4.0_RP * PI)
       Pl = Pl / (4.0_RP * PI)

      ! get total accoustic pressure as the sum of the two components (the quadrapol terms are being ignored)
       Pacc = (/Pt, Pl, Pt+Pl/)

   End Function FWHSurfaceIntegral 

!/////////////////////////////////////////////////////////////////////////
!           ZONE PROCEDURES --------------------------
!/////////////////////////////////////////////////////////////////////////

   Subroutine SourceProlongSolution(source_zone, mesh)

!     *******************************************************************
!        This subroutine prolong the solution from the mesh storage to the faces (source).
!         TODO: use openmp (commented)
!         TODO: use mpi (see surface integral)
!     *******************************************************************
!
      use ElementClass
      implicit none
      class (Zone_t), intent(in)                           :: source_zone
      class (HexMesh), intent(inout), target               :: mesh

      ! local variables
      integer                                              :: zoneFaceID, meshFaceID, eID
      integer, dimension(6)                                :: meshFaceIDs
      class(Element), pointer                              :: elements(:)

!     *************************
!     Perform the interpolation
!     *************************
!
      elements => mesh % elements
!$omp parallel private(meshFaceID,eID,meshFaceIDs) shared(elements,mesh,NodalStorage)
!!$omp&                                        t)
!$omp single

!        Loop the zone to get faces and elements
!        ---------------------------------------
      do zoneFaceID = 1, source_zone % no_of_faces
          meshFaceID = source_zone % faces(zoneFaceID)

         eID = mesh % faces(meshFaceID) % elementIDs(1)
         meshFaceIDs = mesh % elements(eID) % faceIDs

!$omp task depend(inout:elements(eID))
         call elements(eID) % ProlongSolutionToFaces(NCONS,&
                                                            mesh % faces(meshFaceIDs(1)),&
                                                            mesh % faces(meshFaceIDs(2)),&
                                                            mesh % faces(meshFaceIDs(3)),&
                                                            mesh % faces(meshFaceIDs(4)),&
                                                            mesh % faces(meshFaceIDs(5)),&
                                                            mesh % faces(meshFaceIDs(6)),&
                                                             computeQdot = .TRUE.)

         ! if ( computeGradients ) then
         !    call elements(eID) % ProlongGradientsToFaces(NGRAD, mesh % faces(meshFaceIDs(1)),&
         !                                     mesh % faces(meshFaceIDs(2)),&
         !                                     mesh % faces(meshFaceIDs(3)),&
         !                                     mesh % faces(meshFaceIDs(4)),&
         !                                     mesh % faces(meshFaceIDs(5)),&
         !                                     mesh % faces(meshFaceIDs(6)) )
         ! end if
!$omp end task
      end do
!$omp end single
!$omp end parallel

   End Subroutine SourceProlongSolution

   Subroutine SourceSaveSolution(source_zone, mesh, time, iter, name, no_of_faces, fGlobID, faceOffset)

!     *******************************************************************
!        This subroutine saves the solution from the face storage to a binary file
!     *******************************************************************
!
      use FaceClass
      use SolutionFile
      use MPI_Process_Info
      use fluiddata
      implicit none
      class (Zone_t), intent(in)                           :: source_zone
      class (HexMesh), intent(in), target                  :: mesh
      real(kind=RP), intent(in)                            :: time
      integer,intent(in)                                   :: iter, no_of_faces
      character(len=*), intent(in)                         :: name
      integer, dimension(:), intent(in)                    :: fGlobID, faceOffset

      ! local variables
      integer                                              :: zoneFaceID, meshFaceID, eID
      integer                                              :: ierr
      integer, dimension(6)                                :: meshFaceIDs
      class(Face), pointer                                 :: faces(:)
      real(kind=RP), dimension(:,:,:), allocatable         :: Q
      real(kind=RP), dimension(NDIM)                       :: x
      integer                                              :: Nx,Ny
      integer                                              :: fid, padding
      integer(kind=AddrInt)                                :: pos
      real(kind=RP)                                        :: refs(NO_OF_SAVED_REFS) 

!
!     Gather reference quantities
!     ---------------------------
      refs(GAMMA_REF) = thermodynamics % gamma
      refs(RGAS_REF)  = thermodynamics % R
      refs(RHO_REF)   = refValues      % rho
      refs(V_REF)     = refValues      % V
      refs(T_REF)     = refValues      % T
      refs(MACH_REF)  = dimensionless  % Mach

!
!     Create new file
!     ---------------
      call CreateNewSolutionFile(trim(name), ZONE_SOLUTION_FILE, mesh % nodeType, &
                                    no_of_faces, iter, time, refs)

      padding = NCONS*2
!
!     Write arrays
!     ------------
      fID = putSolutionFileInWriteDataMode(trim(name))
      faces => mesh % faces
!     Loop the zone to get faces
!     ---------------------------------------
      do zoneFaceID = 1, source_zone % no_of_faces
          meshFaceID = source_zone % faces(zoneFaceID)

          Nx = faces(meshFaceID) % Nf(1)
          Ny = faces(meshFaceID) % Nf(2)

          allocate (Q(1:NCONS,0:Nx,0:Ny))

          Q(1:NCONS,:,:)  = faces(meshFaceID) % storage(1) % Q(:,:,:)

          ! 4 integers are written: number of dimension, and 3 value of the dimensions
          pos = POS_INIT_DATA + (fGlobID(zoneFaceID)-1)*4_AddrInt*SIZEOF_INT + padding * faceOffset(zoneFaceID) * SIZEOF_RP
          call writeArray(fid, Q, position=pos)

          Q(1:NCONS,:,:)  = faces(meshFaceID) % storage(1) % Qdot(:,:,:)
          write(fid) Q

          safedeallocate(Q)
      end do

     close(fid)
!
!    Close the file
!    --------------
     call SealSolutionFile(trim(name))

   End Subroutine SourceSaveSolution

   Subroutine SourceLoadSolution(source_zone, mesh, fileName, fGlobID, faceOffset)

      use SolutionFile
      implicit none
      class (Zone_t), intent(in)                           :: source_zone
      class (HexMesh), intent(inout)                       :: mesh
      character(len=*), intent(in)                         :: fileName
      integer, dimension(:), intent(in)                    :: fGlobID, faceOffset

      ! local variables
      integer                                              :: zoneFaceID, meshFaceID
      real(kind=RP), dimension(:,:,:), allocatable         :: QF
      integer                                              :: Nx,Ny
      integer                                              :: fID, pos, padding
      integer                                              :: arrayRank, Neq, Npx, Npy

!     Read elements data
!     ------------------
      fID = putSolutionFileInReadDataMode(trim(fileName))

      padding = NCONS*2
!
!     Loop the zone to get faces and elements
!     ---------------------------------------
      do zoneFaceID = 1, source_zone % no_of_faces
          meshFaceID = source_zone % faces(zoneFaceID)
          ! 4 integers were written: number of dimension, and 3 value of the dimensions
          pos = POS_INIT_DATA + (fGlobID(zoneFaceID)-1)*4*SIZEOF_INT + padding * faceOffset(zoneFaceID) * SIZEOF_RP
          associate(f => mesh % faces(meshFaceID))
              Nx = f % Nf(1)
              Ny = f % Nf(2)
!             verify dimensions of each row
              read(fID, pos=pos) arrayRank
              read(fID) Neq, Npx, Npy
              if (     ((Npx-1) .ne. Nx) &
                  .or. ((Npy-1) .ne. Ny) &
                  .or. (Neq     .ne. NCONS ) ) then
                  write(STD_OUT,'(A,I0,A)') "Error reading fwh file: wrong dimension for face "&
                      ,meshFaceID,"."

                  write(STD_OUT,'(A,I0,A,I0,A)') "Face dimensions: ", Nx, &
                      " ,", Ny, "."

                  write(STD_OUT,'(A,I0,A,I0,A)') "File dimensions: ", Npx -1, &
                      " ,", Npy-1, "."
                  errorMessage(STD_OUT)
                  stop
              end if

              allocate(QF(1:NCONS,0:Nx,0:Ny))
              read(fID) QF
              f % storage(1) % Q = QF
              read(fID) QF
              f % storage(1) % Qdot = QF
              safedeallocate(QF)
          end associate
      end do

!     Close the file
!     --------------
      close(fID)

   End Subroutine SourceLoadSolution

   Subroutine SourcePrepareForIO(source_zone, mesh, totalNumberOfFaces, globalFaceID, faceOffset)

!     *******************************************************************
!        This subroutine creates the arrays necessary for the face binary file
!     *******************************************************************
!
      use FaceClass
      use MPI_Process_Info
      implicit none
      class (Zone_t), intent(in)                           :: source_zone
      class (HexMesh), intent(in), target                  :: mesh
      integer,intent(in)                                   :: totalNumberOfFaces
      integer, dimension(source_zone % no_of_faces), intent(out)          :: globalFaceID, faceOffset

      ! local variables
      integer                                              :: zoneFaceID, meshFaceID, eID, i
      integer, dimension(:), allocatable                   :: gFid, facesSizes, allfacesSizes, allFacesOffset
      integer, dimension(:,:), allocatable                 :: zoneInfoArray
      ! integer, dimension(:), allocatable                 :: zoneInfoArray
      integer                                              :: ierr, fID
      class(Face), pointer                                 :: faces(:)
      integer, dimension(MPI_Process % nProcs)             :: no_of_faces_p, displs
      integer, dimension(1)                                :: idInGlobal

      faces => mesh % faces

!     *******************************************************************
!     Get the globalFaceID
!     *******************************************************************

      allocate(gFid(totalNumberOfFaces))
      allocate(zoneInfoArray(totalNumberOfFaces,2))

      if ( (MPI_Process % doMPIAction) ) then
#ifdef _HAS_MPI_
          call mpi_gather(source_zone % no_of_faces,1,MPI_INT,no_of_faces_p,1,MPI_INT,0,MPI_COMM_WORLD,ierr)

      if (MPI_Process % isRoot) then
          displs=0
          do i = 2, MPI_Process % nProcs 
              displs(i) = displs(i-1) + no_of_faces_p(i-1)
          end do
      end if

      ! get the global element ID and the face ID as a single 2D array for the root process, will be used to sort
      call mpi_gatherv(mesh % elements(faces(source_zone % faces) % elementIDs(1)) % globID, source_zone % no_of_faces,MPI_INT, &
                                     zoneInfoArray(:,1), no_of_faces_p, displs, MPI_INT, 0, MPI_COMM_WORLD, ierr)
      call mpi_gatherv(source_zone % faces, source_zone % no_of_faces,MPI_INT, &
                                     zoneInfoArray(:,2), no_of_faces_p, displs, MPI_INT, 0, MPI_COMM_WORLD, ierr)
      ! get the sorted array
      if (MPI_Process % isRoot) then
          gFid = getGlobalFaceIDs(zoneInfoArray, totalNumberOfFaces)
      end if

      ! distribute to all partitions
      call mpi_scatterv(gFid, no_of_faces_p, displs, MPI_INT, globalFaceID, source_zone % no_of_faces, MPI_INT, 0, MPI_COMM_WORLD, ierr)
#endif
      else
          zoneInfoArray(:,1) = mesh % elements(faces(source_zone % faces) % elementIDs(1)) % globID
          zoneInfoArray(:,2) = source_zone % faces
          ! get the sorted array
          globalFaceID = getGlobalFaceIDs(zoneInfoArray, totalNumberOfFaces)
      end if

!     Free memory
!     -----------
      deallocate(gFid, zoneInfoArray)

!     *******************************************************************
!     Get the faceOffset, similar to HexMesh_PrepareForIO, but for faces
!     *******************************************************************

!     Get each face storage size
!     ---------------------
      allocate(facesSizes(totalNumberOfFaces), allfacesSizes(totalNumberOfFaces))

      facesSizes = 0 ! default to use allreduce
      do zoneFaceID = 1, source_zone % no_of_faces
          ! globalFaceID index
          fID = globalFaceID(zoneFaceID)
          meshFaceID = source_zone % faces(zoneFaceID)
          facesSizes(fID) = ( faces(meshFaceID) % Nf(1) +1 ) * ( faces(meshFaceID) % Nf(2) +1 )
      end do

      allfacesSizes = 0
      if ( (MPI_Process % doMPIAction) ) then
#ifdef _HAS_MPI_
          call mpi_allreduce(facesSizes, allfacesSizes, totalNumberOfFaces, MPI_INT, MPI_SUM, MPI_COMM_WORLD, ierr)
#endif
      else
          allfacesSizes = facesSizes
      end if
    
!     Get all faces offset: the accumulation of allfacesSizes
!     -----------------------
      allocate(allFacesOffset(totalNumberOfFaces))

      allFacesOffset(1) = 0
      do fID = 2, totalNumberOfFaces
          allFacesOffset(fID) = allFacesOffset(fID-1) + allfacesSizes(fID-1)
      end do

!     Assign the results to partitions' array
!     ----------------------------------
      do zoneFaceID = 1, source_zone % no_of_faces
          fID = globalFaceID(zoneFaceID)
          faceOffset(zoneFaceID) = allFacesOffset(fID)
      end do

!     Free memory
!     -----------
      deallocate(facesSizes, allfacesSizes, allFacesOffset)

   End Subroutine SourcePrepareForIO

   Function getGlobalFaceIDs(zoneInfoArray, N) result(gID)
!     *******************************************************************
!        This function gets a unique identifier of each face of the source_zone,
!        in a unique order needed for I/O
!     *******************************************************************

      use Utilities, only: QsortWithFriend
      implicit none

      integer,dimension(N,2),intent(in)                    :: zoneInfoArray
      integer,intent(in)                                   :: N
      integer,dimension(N)                                 :: giD

      ! local variables
      integer,dimension(N)                                 :: originalIndex, orderedIndex, toOrderArray
      integer                                              :: bigInt, i, maxF, nDigits

      maxF = maxval(zoneInfoArray(:,2))
      nDigits = 0
      ! get number of digits of maxF
      do while (maxF .ne. 0)
          maxF = maxF / 10
          nDigits = nDigits + 1
      end do
      ! convert the two arrays as a one of integers that can be sort, first by the globID of the element and the by the faceID
      bigInt = 10 ** nDigits
      toOrderArray = bigInt * zoneInfoArray(:,1) + zoneInfoArray(:,2)
      ! create simple arrays of indexes
      originalIndex = [(i, i=1,N)]
      orderedIndex = [(i, i=1,N)]
      call QsortWithFriend(toOrderArray,originalIndex)
      ! get the indexes of orders`
      call QsortWithFriend(originalIndex, orderedIndex)
      gID = orderedIndex

   End Function getGlobalFaceIDs

   Subroutine SourceLoadSurfaceFromFile(mesh, surface_file, facesIDs, numberOfFaces, eIDs)

!     *******************************************************************
!        This subroutine reads the faces of the surface from a text file
!     *******************************************************************
!
      use MPI_Process_Info
      implicit none

      class(HexMesh), intent(in)                          :: mesh
      character(len=LINE_LENGTH), intent(in)              :: surface_file
      integer, dimension(:), allocatable, intent(out)     :: facesIDs, eIDs
      integer, intent(out)                                :: numberOfFaces

      ! local variables
      integer                                             :: fd       ! File unit
      integer                                             :: i        ! counter
      integer, dimension(:), allocatable                  :: geIDs
         
      open(newunit = fd, file = surface_file )   
      read(fd,*) numberOfFaces

      allocate( facesIDs(numberOfFaces), geIDs(numberOfFaces) )

      do i = 1, numberOfFaces
      read(fd,*) geIDs(i), facesIDs(i)
      end do
      close(unit=fd)
      eIDs = geIDs

   End Subroutine SourceLoadSurfaceFromFile

!/////////////////////////////////////////////////////////////////////////
!           AUXILIAR PROCEDURES --------------------------
!/////////////////////////////////////////////////////////////////////////

! get the interpolated value of an array
! ------------
  Function linearInterpolation(x, x1, y1, x2, y2, N) result(y)

      integer, intent(in)                           :: N
      real(kind=RP), intent(in)                     :: x1, x2, x
      real(kind=RP), dimension(N), intent(in)       :: y1, y2
      real(kind=RP), dimension(N)                   :: y

      y = y1 + (y2-y1)/(x2-x1) * (x - x1)

  End Function linearInterpolation

   Subroutine calculateFWHVariables(Q, Qdot, isSolid, Qi, QiDot, Lij, LijDot)

       use VariableConversion, only: Pressure, PressureDot
       use FWHDefinitions,     only: rho0, P0, c0, U0, M0
       use Utilities, only: AlmostEqual
       implicit none

       real(kind=RP), dimension(NCONS), intent(in)         :: Q        ! horses variables array
       real(kind=RP), dimension(NCONS), intent(in)         :: Qdot     ! horses time derivatives array
       logical, intent(in)                                 :: isSolid
       real(kind=RP), dimension(NDIM), intent(out)         :: Qi       ! fwh Qi array, related with the accoustic pressure thickness
       real(kind=RP), dimension(NDIM), intent(out)         :: Qidot
       real(kind=RP), dimension(NDIM,NDIM), intent(out)    :: Lij      ! fwh Lij tensor: related with the accoustic pressure loading
       real(kind=RP), dimension(NDIM,NDIM), intent(out)    :: LijDot

       !local variables
       real(kind=RP)                                       :: P, pDot
       real(kind=RP), dimension(NDIM,NDIM)                 :: Pij      ! fwh perturbation stress tensor
       ! real(kind=RP), dimension(NDIM:NDIM)                 :: tau
       integer                                             :: i, j, ii, jj

       P = Pressure(Q)
       pDot = PressureDot(Q,Qdot)

       Pij = 0.0_RP
       LijDot = 0.0_RP
       do i=1,NDIM
           Pij(i,i) = P - P0
           !pressure derivative of LijDot
           LijDot(i,i) = pDot
       end do

       !TODO use the stress tensor and the time derivative for Lij and LijDot respectively
       ! call getStressTensor(Q, U_x, U_y, U_z, tau)
       ! Pij = Pij - tau
       ! LijDot = LijDot - tauDot

       ! set values for solid (impermeable) surface
       Qi(:) = -rho0*U0(:)
       Qidot = 0.0_RP
       Lij = Pij
       ! Lij = 0.0_RP

       !calculate terms for permable surface
       if (.not. isSolid) then
           Qi(:) = Qi(:) + Q(2:4)
           ! convert to complete velocity instead of perturbation velocity
           QiDot(:) = QiDot(:) + Qdot(2:4)

           do j = 1, NDIM
               jj = j + 1
               do i = 1, NDIM
                   ! one index is added since rhoV1 = Q(2), rhoV2 = Q(3) ...
                   ii = i + 1
                   Lij(i,j) = Lij(i,j) + (Q(ii) - Q(1)*U0(i))*(Q(jj)/Q(1))
                   LijDot(i,j) = LijDot(i,j) + ( Qdot(ii) - Q(ii)/Q(1)*Qdot(1) )/Q(1) * Q(jj) + &
                                               (Q(ii)/Q(1) - U0(i)) * Qdot(jj)
               end do  
           end do  
       end if

   End Subroutine calculateFWHVariables

End Module  FWHObseverClass 
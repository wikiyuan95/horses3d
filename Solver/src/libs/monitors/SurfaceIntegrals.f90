#include "Includes.h"
#if defined(NAVIERSTOKES)
module SurfaceIntegrals
   use SMConstants
   use PhysicsStorage
   use Physics
   use FaceClass
   use ElementClass
   use HexMeshClass
   use VariableConversion, only: Pressure
   use NodalStorageClass
#ifdef _HAS_MPI_
   use mpi
#endif
   implicit none

   private
   public   SURFACE, TOTAL_FORCE, PRESSURE_FORCE, VISCOUS_FORCE, MASS_FLOW, FLOW_RATE, PRESSURE_DISTRIBUTION
   public   ScalarSurfaceIntegral, VectorSurfaceIntegral, ScalarDataReconstruction, VectorDataReconstruction

   integer, parameter   :: SURFACE = 1
   integer, parameter   :: TOTAL_FORCE = 2
   integer, parameter   :: PRESSURE_FORCE = 3
   integer, parameter   :: VISCOUS_FORCE = 4
   integer, parameter   :: MASS_FLOW = 5
   integer, parameter   :: FLOW_RATE = 6
   integer, parameter   :: PRESSURE_DISTRIBUTION = 7
   integer, parameter   :: USER_DEFINED = 99
!
!  ========
   contains
!  ========
!
!////////////////////////////////////////////////////////////////////////////////////////
!
!           SCALAR INTEGRALS PROCEDURES
!
!////////////////////////////////////////////////////////////////////////////////////////
!
      function ScalarSurfaceIntegral(mesh, zoneID, integralType, iter) result(val)
!
!        -----------------------------------------------------------
!           This function computes scalar integrals, that is, those
!           in the form:
!                 val = \int \vec{v}·\vec{n}dS
!           Implemented integrals are:
!              * Surface: computes the zone surface.
!              * Mass flow: computes the mass flow across the zone.
!              * Flow: computes the volumetric flow across the zone.
!        -----------------------------------------------------------
!
         implicit none
         class(HexMesh),      intent(inout), target  :: mesh
         integer,             intent(in)    :: zoneID
         integer,             intent(in)    :: integralType, iter
         real(kind=RP)                      :: val, localval
!
!        ---------------
!        Local variables
!        ---------------
!
         integer  :: zonefID, fID, eID, fIDs(6), ierr
         class(Element), pointer    :: elements(:)
!
!        Initialization
!        --------------
         val = 0.0_RP
!
!        Loop the zone to get faces and elements
!        ---------------------------------------
         elements => mesh % elements
!$omp parallel private(fID, eID, fIDs) shared(elements,mesh,NodalStorage,zoneID,integralType,val,&
!$omp&                                          computeGradients)
!$omp single
         do zonefID = 1, mesh % zones(zoneID) % no_of_faces
            fID = mesh % zones(zoneID) % faces(zonefID)

            eID = mesh % faces(fID) % elementIDs(1)
            fIDs = mesh % elements(eID) % faceIDs

!$omp task depend(inout:elements(eID))
            call elements(eID) % ProlongSolutionToFaces(NCONS, mesh % faces(fIDs(1)),&
                                            mesh % faces(fIDs(2)),&
                                            mesh % faces(fIDs(3)),&
                                            mesh % faces(fIDs(4)),&
                                            mesh % faces(fIDs(5)),&
                                            mesh % faces(fIDs(6)) )
            if ( computeGradients ) then
               call elements(eID) % ProlongGradientsToFaces(NGRAD, mesh % faces(fIDs(1)),&
                                                mesh % faces(fIDs(2)),&
                                                mesh % faces(fIDs(3)),&
                                                mesh % faces(fIDs(4)),&
                                                mesh % faces(fIDs(5)),&
                                                mesh % faces(fIDs(6)) )
            end if
!$omp end task
         end do
!$omp end single
!
!        Loop the zone to get faces and elements
!        ---------------------------------------
!$omp do private(fID) reduction(+:val) schedule(runtime)
         do zonefID = 1, mesh % zones(zoneID) % no_of_faces
!
!           Face global ID
!           --------------
            fID = mesh % zones(zoneID) % faces(zonefID)
!
!           Compute the integral
!           --------------------
            val = val + ScalarSurfaceIntegral_Face(mesh % faces(fID), integralType)

         end do
!$omp end do
!$omp end parallel

#ifdef _HAS_MPI_
         localval = val
         call mpi_allreduce(localval, val, 1, MPI_DOUBLE, MPI_SUM, MPI_COMM_WORLD, ierr)
#endif

      end function ScalarSurfaceIntegral

      function ScalarSurfaceIntegral_Face(f, integralType) result(val)
         implicit none
         class(Face),                 intent(in)     :: f
         integer,                     intent(in)     :: integralType
         real(kind=RP)                               :: val
!
!        ---------------
!        Local variables
!        ---------------
!
         integer                       :: i, j      ! Face indices
         real(kind=RP)                 :: p
         type(NodalStorage_t), pointer :: spAxi, spAeta
!
!        Initialization
!        --------------
         val = 0.0_RP
         spAxi  => NodalStorage(f % Nf(1))
         spAeta => NodalStorage(f % Nf(2))
!
!        Perform the numerical integration
!        ---------------------------------
         associate( Q => f % storage(1) % Q )
         select case ( integralType )
         case ( SURFACE )
!
!           **********************************
!           Computes the surface integral
!              val = \int dS
!           **********************************
!
            do j = 0, f % Nf(2) ;    do i = 0, f % Nf(1)
               val = val + spAxi % w(i) * spAeta % w(j) * f % geom % jacobian(i,j)
            end do          ;    end do

         case ( MASS_FLOW )
!
!           ***********************************
!           Computes the mass-flow integral
!              I = \int rho \vec{v}·\vec{n}dS
!           ***********************************
!
            do j = 0, f % Nf(2) ;    do i = 0, f % Nf(1)
!
!              Compute the integral
!              --------------------
               val = val +  (Q(IRHOU,i,j) * f % geom % normal(1,i,j)  &
                          + Q(IRHOV,i,j) * f % geom % normal(2,i,j)  &
                          + Q(IRHOW,i,j) * f % geom % normal(3,i,j) ) &
                       * spAxi % w(i) * spAeta % w(j) * f % geom % jacobian(i,j)

            end do          ;    end do

         case ( FLOW_RATE )
!
!           ***********************************
!           Computes the flow integral
!              val = \int \vec{v}·\vec{n}dS
!           ***********************************
!
            do j = 0, f % Nf(2) ;    do i = 0, f % Nf(1)
!
!              Compute the integral
!              --------------------
               val = val + (1.0_RP / Q(IRHO,i,j))*(Q(IRHOU,i,j) * f % geom % normal(1,i,j)  &
                                             + Q(IRHOV,i,j) * f % geom % normal(2,i,j)  &
                                             + Q(IRHOW,i,j) * f % geom % normal(3,i,j) ) &
                                          * spAxi % w(i) * spAeta % w(j) * f % geom % jacobian(i,j)
            end do          ;    end do

         case ( PRESSURE_FORCE )
!
!           ***********************************
!           Computes the pressure integral
!              val = \int pdS
!           ***********************************
!
            do j = 0, f % Nf(2) ;    do i = 0, f % Nf(1)
!
!              Compute the integral
!              --------------------
               p = Pressure(Q(:,i,j))
               val = val + p * spAxi % w(i) * spAeta % w(j) * f % geom % jacobian(i,j)
            end do          ;    end do


         case ( USER_DEFINED )   ! TODO
         end select
         end associate

         nullify (spAxi, spAeta)
      end function ScalarSurfaceIntegral_Face
!
!////////////////////////////////////////////////////////////////////////////////////////
!
!           VECTOR INTEGRALS PROCEDURES
!
!////////////////////////////////////////////////////////////////////////////////////////
!
      function VectorSurfaceIntegral(mesh, zoneID, integralType, iter) result(val)
!
!        -----------------------------------------------------------
!           This function computes scalar integrals, that is, those
!           in the form:
!                 val = \int \vec{v}·\vec{n}dS
!           Implemented integrals are:
!              * Surface: computes the zone surface.
!              * Mass flow: computes the mass flow across the zone.
!              * Flow: computes the volumetric flow across the zone.
!        -----------------------------------------------------------
!
#ifdef _HAS_MPI_
         use mpi
#endif
         implicit none
         class(HexMesh),      intent(inout), target  :: mesh 
         integer,             intent(in)    :: zoneID
         integer,             intent(in)    :: integralType, iter
         real(kind=RP)                      :: val(NDIM)
         real(kind=RP)                      :: localVal(NDIM)
         real(kind=RP)                      :: valx, valy, valz
!
!        ---------------
!        Local variables
!        ---------------
!
         integer  :: zonefID, fID, eID, fIDs(6), ierr
         class(Element), pointer  :: elements(:)
!
!        Initialization
!        --------------
         val = 0.0_RP
         valx = 0.0_RP
         valy = 0.0_RP
         valz = 0.0_RP
!
!        *************************
!        Perform the interpolation
!        *************************
!
         elements => mesh % elements
!$omp parallel private(fID, eID, fIDs, localVal) shared(elements,mesh,NodalStorage,zoneID,integralType,val,&
!$omp&                                        valx,valy,valz,computeGradients)
!$omp single
         do zonefID = 1, mesh % zones(zoneID) % no_of_faces
            fID = mesh % zones(zoneID) % faces(zonefID)

            eID = mesh % faces(fID) % elementIDs(1)
            fIDs = mesh % elements(eID) % faceIDs

!$omp task depend(inout:elements(eID))
            call elements(eID) % ProlongSolutionToFaces(NCONS, mesh % faces(fIDs(1)),&
                                            mesh % faces(fIDs(2)),&
                                            mesh % faces(fIDs(3)),&
                                            mesh % faces(fIDs(4)),&
                                            mesh % faces(fIDs(5)),&
                                            mesh % faces(fIDs(6)) )
            if ( computeGradients ) then
               call elements(eID) % ProlongGradientsToFaces(NGRAD, mesh % faces(fIDs(1)),&
                                                mesh % faces(fIDs(2)),&
                                                mesh % faces(fIDs(3)),&
                                                mesh % faces(fIDs(4)),&
                                                mesh % faces(fIDs(5)),&
                                                mesh % faces(fIDs(6)) )
            end if
!$omp end task
         end do
!$omp end single
!
!        Loop the zone to get faces and elements
!        ---------------------------------------
!$omp do private(fID,localVal) reduction(+:valx,valy,valz) schedule(runtime)
         do zonefID = 1, mesh % zones(zoneID) % no_of_faces
!
!           Face global ID
!           --------------
            fID = mesh % zones(zoneID) % faces(zonefID)
!
!           Compute the integral
!           --------------------
            localVal = VectorSurfaceIntegral_Face(mesh % faces(fID), integralType)
            valx = valx + localVal(1)
            valy = valy + localVal(2)
            valz = valz + localVal(3)

         end do
!$omp end do
!$omp end parallel

         val = (/valx, valy, valz/)

#ifdef _HAS_MPI_
         localVal = val
         call mpi_allreduce(localVal, val, NDIM, MPI_DOUBLE, MPI_SUM, MPI_COMM_WORLD, ierr)
#endif

      end function VectorSurfaceIntegral

      function VectorSurfaceIntegral_Face(f, integralType) result(val)
         implicit none
         class(Face),                 intent(in)     :: f
         integer,                     intent(in)     :: integralType
         real(kind=RP)                               :: val(NDIM)
!
!        ---------------
!        Local variables
!        ---------------
!
         integer                       :: i, j      ! Face indices
         real(kind=RP)                 :: p, tau(NDIM,NDIM)
         type(NodalStorage_t), pointer :: spAxi, spAeta
!
!        Initialization
!        --------------
         val = 0.0_RP
         spAxi  => NodalStorage(f % Nf(1))
         spAeta => NodalStorage(f % Nf(2))
!
!        Perform the numerical integration
!        ---------------------------------
         associate( Q => f % storage(1) % Q, &
                  U_x => f % storage(1) % U_x, &
                  U_y => f % storage(1) % U_y, &
                  U_z => f % storage(1) % U_z   )
         select case ( integralType )
         case ( SURFACE )
!
!           **********************************
!           Computes the surface integral
!              val = \int \vec{n} dS
!           **********************************
!
            do j = 0, f % Nf(2) ;    do i = 0, f % Nf(1)
               val = val + spAxi % w(i) * spAeta % w(j) * f % geom % jacobian(i,j) &
                         * f % geom % normal(:,i,j)
            end do          ;    end do

         case ( TOTAL_FORCE )
!
!           ************************************************
!           Computes the total force experienced by the zone
!              F = \int p \vec{n}ds - \int tau'·\vec{n}ds
!           ************************************************
!
            do j = 0, f % Nf(2) ;    do i = 0, f % Nf(1)
!
!              Compute the integral
!              --------------------
               p = Pressure(Q(:,i,j))
               call getStressTensor(Q(:,i,j),U_x(:,i,j),U_y(:,i,j),U_z(:,i,j), tau)

               val = val + ( p * f % geom % normal(:,i,j) - matmul(tau,f % geom % normal(:,i,j)) ) &
                           * f % geom % jacobian(i,j) * spAxi % w(i) * spAeta % w(j)

            end do          ;    end do

         case ( PRESSURE_FORCE )
!
!           ****************************************************
!           Computes the pressure forces experienced by the zone
!              F = \int p \vec{n}ds
!           ****************************************************
!
            do j = 0, f % Nf(2) ;    do i = 0, f % Nf(1)
!
!              Compute the integral
!              --------------------
               p = Pressure(Q(:,i,j))

               val = val + ( p * f % geom % normal(:,i,j) ) * f % geom % jacobian(i,j) &
                         * spAxi % w(i) * spAeta % w(j)

            end do          ;    end do

         case ( VISCOUS_FORCE )
!
!           ************************************************
!           Computes the total force experienced by the zone
!              F =  - \int tau'·\vec{n}ds
!           ************************************************
!
            do j = 0, f % Nf(2) ;    do i = 0, f % Nf(1)
!
!              Compute the integral
!              --------------------
               call getStressTensor(Q(:,i,j),U_x(:,i,j),U_y(:,i,j),U_z(:,i,j), tau)
               val = val - matmul(tau,f % geom % normal(:,i,j)) * f % geom % jacobian(i,j) &
                           * spAxi % w(i) * spAeta % w(j)

            end do          ;    end do

         case ( USER_DEFINED )   ! TODO

         end select
         end associate
         nullify (spAxi, spAeta)
      end function VectorSurfaceIntegral_Face

!
!////////////////////////////////////////////////////////////////////////////////////////
!
!           INTEGRALS PROCEDURES FOR IBM DATA RECONSTRUCTION
!
!                          SURFACE INTEGRALS
!
!////////////////////////////////////////////////////////////////////////////////////////
   subroutine ScalarDataReconstruction( IBM, elements, STLNum, integralType, iter ) 
      use TessellationTypes
      use MappedGeometryClass
      use IBMClass
      use OrientedBoundingBox
      use KDClass
      use MPI_Process_Info
      use MPI_IBMUtilities
#ifdef _HAS_MPI_
      use mpi
#endif
!
!        -----------------------------------------------------------------------------------------
!           This function computes Scalar integrals, that is, those
!           in the form:
!                 val = \int \vec{v}·\vec{n}dS
!           The data at the boundary point (BP) is computed through a Inverse Distance Weight
!           procedure. 
!        -----------------------------------------------------------------------------------------
      implicit none
      !-arguments--------------------------------------------------------
      type(IBM_type),   intent(inout) :: IBM
      type(element),    intent(in)    :: elements(:)
      integer,          intent(in)    :: integralType, STLNum, iter
      !-local-variables-------------------------------------------------
      real(kind=rp)               :: Dist
      real(kind=rp), allocatable  :: InterpolatedValue(:,:)
      integer                     :: i, j, k
       
      if( .not. IBM% Integral(STLNum)% compute ) return
       
      allocate( InterpolatedValue(size(IBM% root(STLNum)% ObjectsList),3) )
      
      call IBM% BandPoint_state(elements, STLNum, .false.)
!$omp parallel 
!$omp do schedule(runtime) private(j,k,Dist)
      do i = 1, size(IBM% root(STLNum)% ObjectsList)
         do j = 1, size(IBM% root(STLNum)% ObjectsList(i)% vertices)
            if( .not. IBM% Integral(STLNum)% ListComputed ) then
               IBM% root(STLNum)% ObjectsList(i)% vertices(j)% nearestPoints = 0
               do k = 1, IBM% NumOfInterPoints
                  call MinimumDistancePoints( IBM% root(STLNum)% ObjectsList(i)% vertices(j)% coords,       &
                                              IBM% rootPoints(STLNum), IBM% BandRegion(STLNum), Dist, k,    & 
                                              IBM% root(STLNum)% ObjectsList(i)% vertices(j)% nearestPoints ) 
               end do 

               call GetMatrixInterpolationSystem( IBM% root(STLNum)% ObjectsList(i)% vertices(j)% coords,                                    &
                                                  IBM% BandRegion(STLNum)% x(IBM% root(STLNum)% ObjectsList(i)% vertices(j)% nearestPoints), &
                                                  IBM% root(STLNum)% ObjectsList(i)% vertices(j)% invPhi,                                    &
                                                  IBM% root(STLNum)% ObjectsList(i)% vertices(j)% b, IBM% InterpolationType                  )

            end if 

            InterpolatedValue(i,j) = InterpolatedScalarValue( Q = IBM% BandRegion(STLNum)% Q(:,IBM% root(STLNum)% ObjectsList(i)% vertices(j)% nearestPoints), &
                                                              invPhi       = IBM% root(STLNum)% ObjectsList(i)% vertices(j)% invPhi,                           &
                                                              b            = IBM% root(STLNum)% ObjectsList(i)% vertices(j)% b,                                &
                                                              normal       = IBM% root(STLNum)% ObjectsList(i)% normal,                                        & 
                                                              integralType = integralType                                                                      )
         end do
      end do
!$omp end do 
!$omp end parallel 
      if( IBM% stl(STLNum)% move ) then
         IBM% Integral(STLNum)% ListComputed = .false.
      else 
         IBM% Integral(STLNum)% ListComputed = .true.
      end if 
      
      call GenerateScalarmonitorTECfile( IBM% root(STLNum)% ObjectsList, InterpolatedValue, STLNum, integralType, iter )
      
      deallocate(InterpolatedValue)

   end subroutine ScalarDataReconstruction
!
!////////////////////////////////////////////////////////////////////////////////////////
!
!                          VECTOR INTEGRALS
!
!////////////////////////////////////////////////////////////////////////////////////////
   subroutine VectorDataReconstruction( IBM, elements, STLNum, integralType, iter )
      use TessellationTypes
      use MappedGeometryClass
      use IBMClass
      use OrientedBoundingBox
      use KDClass
      use MPI_Process_Info
      use MPI_IBMUtilities
      use omp_lib
#ifdef _HAS_MPI_
      use mpi
#endif
!
!        -----------------------------------------------------------------------------------------
!           This function computes Vector integrals, that is, those
!           in the form:
!                 val = \int \vec{v}·\vec{n}dS
!           The data at the boundary point (BP) is computed through a Inverse Distance Weight
!           procedure. 
!        -----------------------------------------------------------------------------------------
      implicit none
      !-arguments---------------------------------------------------------------------------------
      type(IBM_type), intent(inout) :: IBM
      type(element),  intent(in)    :: elements(:)
      integer,        intent(in)    :: integralType, STLNum, iter
      !-local-variables---------------------------------------------------------------------------
      real(kind=rp)              :: Dist, LocNormal(NDIM), v(NDIM), w(NDIM)
      integer                    :: i, j, k
      real(kind=RP), allocatable :: IntegratedValue(:,:,:)

      if( .not. IBM% Integral(STLNum)% compute ) return

      allocate( IntegratedValue(NDIM,size(IBM% root(STLNum)% ObjectsList),3) )
 
      call IBM% BandPoint_state( elements, STLNum, .true. )
!$omp parallel 
!$omp do schedule(runtime) private(j,k,Dist,v,w,LocNormal)
      do i = 1, size(IBM% root(STLNum)% ObjectsList)
         do j = 1, size(IBM% root(STLNum)% ObjectsList(i)% vertices)
            if( .not. IBM% Integral(STLNum)% ListComputed ) then   
               IBM% root(STLNum)% ObjectsList(i)% vertices(j)% nearestPoints = 0
               do k = 1, IBM% NumOfInterPoints     
                  if( IBM% Wallfunction ) then 
                     v = IBM% root(STLNum)% ObjectsList(i)% vertices(2)% coords-IBM% root(STLNum)% ObjectsList(i)% vertices(1)% coords
                     w = IBM% root(STLNum)% ObjectsList(i)% vertices(3)% coords-IBM% root(STLNum)% ObjectsList(i)% vertices(1)% coords

                     LocNormal(1) = v(2)*w(3) - v(3)*w(2); LocNormal(2) = v(3)*w(1) - v(1)*w(3); LocNormal(3) = v(1)*w(2) - v(2)*w(1)
                     LocNormal = LocNormal/norm2(LocNormal)
                     call MinimumDistancePoints( IBM% root(STLNum)% ObjectsList(i)% vertices(j)% coords + IBM% IP_Distance*LocNormal, &
                                                 IBM% rootPoints(STLNum), IBM% BandRegion(STLNum), Dist, k,                           &
                                                 IBM% root(STLNum)% ObjectsList(i)% vertices(j)% nearestPoints                        )
                  else           
                     call MinimumDistancePoints( IBM% root(STLNum)% ObjectsList(i)% vertices(j)% coords,       &
                                                 IBM% rootPoints(STLNum), IBM% BandRegion(STLNum), Dist, k,    &
                                                 IBM% root(STLNum)% ObjectsList(i)% vertices(j)% nearestPoints )   
                  end if 
               end do

               call GetMatrixInterpolationSystem( IBM% root(STLNum)% ObjectsList(i)% vertices(j)% coords,                                    &
                                                  IBM% BandRegion(STLNum)% x(IBM% root(STLNum)% ObjectsList(i)% vertices(j)% nearestPoints), &
                                                  IBM% root(STLNum)% ObjectsList(i)% vertices(j)% invPhi,                                    &
                                                  IBM% root(STLNum)% ObjectsList(i)% vertices(j)% b, IBM% InterpolationType                  )
            end if 
            
            IntegratedValue(:,i,j) = IntegratedVectorValue( Q   = IBM% BandRegion(STLNum)%Q(:,IBM% root(STLNum)% ObjectsList(i)% vertices(j)% nearestPoints),   &
                                                            U_x = IBM% BandRegion(STLNum)%U_x(:,IBM% root(STLNum)% ObjectsList(i)% vertices(j)% nearestPoints), & 
                                                            U_y = IBM% BandRegion(STLNum)%U_y(:,IBM% root(STLNum)% ObjectsList(i)% vertices(j)% nearestPoints), &
                                                            U_z = IBM% BandRegion(STLNum)%U_z(:,IBM% root(STLNum)% ObjectsList(i)% vertices(j)% nearestPoints), &
                                                            invPhi        = IBM% root(STLNum)% ObjectsList(i)% vertices(j)% invPhi,                             &
                                                            b             = IBM% root(STLNum)% ObjectsList(i)% vertices(j)% b,                                  &
                                                            normal        = IBM% root(STLNum)% ObjectsList(i)% normal,                                          &
                                                            y             = IBM% IP_Distance,                                                                   &
                                                            Wallfunction  = IBM% Wallfunction,                                                                  &
                                                            integralType  = integralType                                                                        )
         end do
      end do
!$omp end do
!$omp end parallel   
      if( IBM% stl(STLNum)% move ) then
         IBM% Integral(STLNum)% ListComputed = .false.
      else
         IBM% Integral(STLNum)% ListComputed = .true.
      end if

      call GenerateVectormonitorTECfile( IBM% root(STLNum)% ObjectsList, IntegratedValue, STLNum, integralType, iter )

      deallocate(IntegratedValue)

   end subroutine VectorDataReconstruction
!
!////////////////////////////////////////////////////////////////////////////////////////
!
!           INVERSE DISTANCE WEIGHTED INTERPOLATION PROCEDURES FOR IBM DATA RECONSTRUCTION
!
!                                   SCALAR INTERPOLATION
!
!//////////////////////////////////////////////////////////////////////////////////////// 
   function InterpolatedScalarValue( Q, invPhi, b, normal, integralType ) result( outvalue )
      use IBMClass
      implicit none
!
!        -----------------------------------------------------------
!           This function computes the IDW interpolat for a scalar
!           quantity in the point "Point".
!           Available scalars are:
!           Mass flow
!           Flow rate
!           Pressure
!        -----------------------------------------------------------
      !-arguments--------------------------------------------------------------
      real(kind=rp),           intent(in) :: Q(:,:), invPhi(:,:), b(:), &
                                             normal(:)
      integer,                 intent(in) :: integralType
      real(kind=rp)                       :: outvalue
      !-local-variables--------------------------------------------------------
      real(kind=rp) :: Qi(NCONS), P
      integer       :: i

      outvalue = 0.0_RP
      
      select case( integralType )

         case( MASS_FLOW )
         
            do i = 1, NCONS 
               Qi(i) = GetInterpolatedValue( Q(i,:), invPhi, b )
            end do 
            
            outvalue = - (1.0_RP / Qi(IRHO))*(Qi(IRHOU)*normal(1) + Qi(IRHOV)*normal(2) + Qi(IRHOW)*normal(3))       
            
         case ( FLOW_RATE )
         
             do i = 1, NCONS 
               Qi(i) = GetInterpolatedValue( Q(i,:), invPhi, b )
            end do 
            
            outvalue = - (Qi(IRHOU)*normal(1) + Qi(IRHOV)*normal(2) + Qi(IRHOW)*normal(3)) 
               
         case( PRESSURE_DISTRIBUTION )
         
             do i = 1, NCONS 
               Qi(i) = GetInterpolatedValue( Q(i,:), invPhi, b )
            end do 
            
            outvalue = pressure(Qi)
         case ( USER_DEFINED )   ! TODO  

      end select 

   end function InterpolatedScalarValue
!
!////////////////////////////////////////////////////////////////////////////////////////
!
!                          VECTOR INTERPOLATION
!
!////////////////////////////////////////////////////////////////////////////////////////         
   function IntegratedVectorValue( Q, U_x, U_y, U_z, invPhi, b, normal, y, Wallfunction, integralType ) result( outvalue )
      use IBMClass
      use VariableConversion
      use FluidData
#if defined(NAVIERSTOKES)
      use WallFunctionBC
#endif
      implicit none
!
!        -----------------------------------------------------------
!           This function computes the IDW interpolat for a vector
!           quantity in the point "Point".
!           Available scalars are:
!           Total force
!           Pressure force
!           Viscous force
!        -----------------------------------------------------------
      !-arguments-----------------------------------------------------------------
      real(kind=rp),           intent(in) :: Q(:,:), U_x(:,:), U_y(:,:),       &
                                             U_z(:,:), normal(:), invPhi(:,:), &
                                             b(:)
      real(kind=rp),           intent(in) :: y
      logical,                 intent(in) :: Wallfunction
      integer,                 intent(in) :: integralType
      real(kind=rp)                       :: outvalue(NDIM)
      !-local-variables-----------------------------------------------------------
      integer       :: i
      real(kind=rp) :: viscStress(NDIM), U(NDIM), U_t(NDIM), tangent(NDIM),   &
                       Qi(NCONS), U_xi(NCONS), U_yi(NCONS), U_zi(NCONS),      & 
                       tau(NDIM,NDIM), P, T, T_w, rho_w, mu, nu, u_II, u_tau, &
                       tau_w, kappa_                                        
      
      outvalue = 0.0_RP

      select case( integralType )

         case ( TOTAL_FORCE )

            do i = 1, NCONS 
               Qi(i) = GetInterpolatedValue( Q(i,:), invPhi, b )
            end do

            P = pressure(Qi)

            if( Wallfunction ) then
#if defined(NAVIERSTOKES) 
               T  = Temperature(Qi)
               call get_laminar_mu_kappa(Qi,mu,kappa_) 
               nu = mu/Qi(IRHO)
                
               U   = Qi(IRHOU:IRHOW)/Qi(IRHO)
               U_t = U - ( dot_product(U,normal) * normal )
 
               tangent = U_t/norm2(U_t)

               u_II  = dot_product(U,tangent)
               
               u_tau = u_tau_f( u_II, y, nu, u_tau0=0.1_RP )
            
               T_w = T + (dimensionless% Pr)**(1._RP/3._RP)/(2.0_RP*thermodynamics% cp) * POW2(u_II)
               T_w = T_w * refvalues% T
               rho_w = P*refvalues% p/(thermodynamics% R * T_w)
               rho_w = rho_w/refvalues% rho
#endif
               tau_w = rho_w*POW2(u_tau)
               
               viscStress = tau_w*tangent
            else
               do i = 1, NCONS 
                  U_xi(i) = GetInterpolatedValue( U_x(i,:), invPhi, b )
                  U_yi(i) = GetInterpolatedValue( U_y(i,:), invPhi, b )
                  U_zi(i) = GetInterpolatedValue( U_z(i,:), invPhi, b )
               end do 
               
               call getStressTensor(Qi, U_xi, U_yi, U_zi, tau)
               
               viscStress = matmul(tau,normal)
            end if
            
            outvalue = -P * normal + viscStress   
                  
         case( PRESSURE_FORCE )
         
            do i = 1, NCONS 
               Qi(i) = GetInterpolatedValue( Q(i,:), invPhi, b )
            end do

            P = pressure(Qi)
            
            outvalue = -P * normal
            
         case( VISCOUS_FORCE )

              if( Wallfunction ) then
#if defined(NAVIERSTOKES) 
               T  = Temperature(Qi)
               call get_laminar_mu_kappa(Qi,mu,kappa_) 
               nu = mu/Qi(IRHO)
                
               U   = Qi(IRHOU:IRHOW)/Qi(IRHO)
               U_t = U - ( dot_product(U,normal) * normal )
 
               tangent = U_t/norm2(U_t)

               u_II  = dot_product(U,tangent)
               
               u_tau = u_tau_f( u_II, y, nu, u_tau0=0.1_RP )
            
               T_w = T + (dimensionless% Pr)**(1._RP/3._RP)/(2.0_RP*thermodynamics% cp) * POW2(u_II)
               T_w = T_w * refvalues% T
               rho_w = P*refvalues% p/(thermodynamics% R * T_w)
               rho_w = rho_w/refvalues% rho
#endif
               tau_w = rho_w*POW2(u_tau)
               
               viscStress = tau_w*tangent
            else
               do i = 1, NCONS 
                  U_xi(i) = GetInterpolatedValue( U_x(i,:), invPhi, b )
                  U_yi(i) = GetInterpolatedValue( U_y(i,:), invPhi, b )
                  U_zi(i) = GetInterpolatedValue( U_z(i,:), invPhi, b )
               end do 
               
               call getStressTensor(Qi, U_xi, U_yi, U_zi, tau)
               
               viscStress = matmul(tau,normal)
            end if 
            
            outvalue = viscStress
            
         case ( USER_DEFINED )   ! TODO  

      end select 

   end function IntegratedVectorValue
   
   subroutine GenerateScalarmonitorTECfile( ObjectsList, scalarState, STLNum, integralType, iter )
      use MPI_Process_Info
      use TessellationTypes
      use MPI_IBMUtilities
      use IBMClass
      implicit none
      !-arguments-------------------------------------------------------
      type(Object_type), intent(in) :: ObjectsList(:)
      real(kind=RP),     intent(in) :: scalarState(:,:)
      integer,           intent(in) :: STLNum, integralType, iter 
      !-local-variables-------------------------------------------------
      real(kind=RP), allocatable :: x(:), y(:), z(:), scalar(:)
      character(len=LINE_LENGTH) :: FileName, FinalName

      if( MPI_Process% doMPIAction ) then
         call sendScalarPlotRoot( ObjectsList, STLNum, scalarState )
      end if 
      if( MPI_Process% isRoot ) then
         call recvScalarPlotRoot( ObjectsList, STLNum, scalarState, x, y, z, scalar )
      end if        
      
      if( .not. MPI_Process% isRoot ) return

      select case(integralType)
         case( MASS_FLOW )
            FileName = 'MASS_FLOW_'
            write(FinalName,'(A,A,I10.10,A)')  trim(FileName),trim(OBB(STLNum)% FileName)//'_',iter,'.tec'
            call STLScalarTEC( x, y, z, scalar, STLNum, FinalName, 'MASS FLOW', '"x","y","z","MassFlow"' )
         case( FLOW_RATE )
            FileName = 'FLOW_RATE_FORCE_'
            write(FinalName,'(A,A,I10.10,A)')  trim(FileName),trim(OBB(STLNum)% FileName)//'_',iter,'.tec'
            call STLScalarTEC( x, y, z, scalar, STLNum, FinalName, 'FLOW RATE', '"x","y","z","FlowRate"' )
         case( PRESSURE_DISTRIBUTION )
            FileName = 'PRESSURE_'
            write(FinalName,'(A,A,I10.10,A)')  trim(FileName),trim(OBB(STLNum)% FileName)//'_',iter,'.tec'
            call STLScalarTEC( x, y, z, scalar, STLNum, FinalName, 'PRESSURE DISTRIBUTION', '"x","y","z","Pressure"' )
      end select

      deallocate(x, y, z, scalar)

  end subroutine GenerateScalarmonitorTECfile
  
  subroutine GenerateVectormonitorTECfile( ObjectsList, vectorState, STLNum, integralType, iter )
      use MPI_Process_Info
      use TessellationTypes
      use MPI_IBMUtilities
      use IBMClass
      implicit none
      !-arguments---------------------------------------------------------
      type(Object_type), intent(in) :: ObjectsList(:)
      real(kind=RP),     intent(in) :: vectorState(:,:,:)
      integer,           intent(in) :: STLNum, integralType, iter 
      !-local-variables---------------------------------------------------
      real(kind=RP), allocatable :: x(:), y(:), z(:), vector_x(:),   &
                                    vector_y(:), vector_z(:)
      character(len=LINE_LENGTH) :: FileName, FinalName
                                    
      if( MPI_Process% doMPIAction ) then
         call sendVectorPlotRoot( ObjectsList, STLNum, vectorState )
      end if 
      if( MPI_Process% isRoot ) then
         call recvVectorPlotRoot( ObjectsList, STLNum, vectorState, x, y, z, vector_x, vector_y, vector_z )
      end if   
      
      if( .not. MPI_Process% isRoot ) return 

      select case(integralType)
         case( TOTAL_FORCE )
            FileName = 'TOTAL_FORCE_'
            write(FinalName,'(A,A,I10.10,A)')  trim(FileName),trim(OBB(STLNum)% FileName)//'_',iter,'.tec'            
            call STLvectorTEC( x, y, z, vector_x, vector_y, vector_z, STLNum, FinalName, 'TOTAL FORCE', '"x","y","z","Ftot_x","Ftot_y","Ftot_z"' )
         case( PRESSURE_FORCE )
            FileName = 'PRESSURE_FORCE_'
            write(FinalName,'(A,A,I10.10,A)')  trim(FileName),trim(OBB(STLNum)% FileName)//'_',iter,'.tec'
            call STLvectorTEC( x, y, z, vector_x, vector_y, vector_z, STLNum, FinalName, 'PRESSURE FORCE', '"x","y","z","Fpres_x","Fpres_y","Fpres_z"' )
         case( VISCOUS_FORCE )
            FileName = 'VISCOUS_FORCE_'
            write(FinalName,'(A,A,I10.10,A)')  trim(FileName),trim(OBB(STLNum)% FileName)//'_',iter,'.tec'
            call STLvectorTEC( x, y, z, vector_x, vector_y, vector_z, STLNum, FinalName, 'VISCOUS FORCE', '"x","y","z","Fvisc_x","Fvisc_y","Fvisc_z"' )
      end select
   
      deallocate(x, y, z, vector_x, vector_y, vector_z)

   end subroutine GenerateVectormonitorTECfile

end module SurfaceIntegrals
#endif
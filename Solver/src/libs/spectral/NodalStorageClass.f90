!
!////////////////////////////////////////////////////////////////////////
!
!      NodalStorage.f95
!      Created: 2008-01-15 10:35:59 -0500 
!      By: David Kopriva 
!
!     Algorithms:
!        Algorithm 
!
!////////////////////////////////////////////////////////////////////////
!
#include "Includes.h"
MODULE NodalStorageClass
   USE SMConstants
   USE PolynomialInterpAndDerivsModule
   USE GaussQuadrature
   IMPLICIT NONE 

   private
   public GAUSS, GAUSSLOBATTO, NodalStorage

   integer, parameter      :: GAUSS = 1
   integer, parameter      :: GAUSSLOBATTO = 2
!
!  -------------------
!  Nodal storage class
!  -------------------
!
   type NodalStorage
      logical                                    :: Constructed = .FALSE.     ! Constructed flag
      integer                                    :: nodes                     ! Either GAUSS or GAUSSLOBATTO
      integer                                    :: N                         ! Polynomial order
      real(kind=RP), dimension(:)  , allocatable :: x                         ! Node position
      real(kind=RP), dimension(:)  , allocatable :: w                         ! Weights
      real(kind=RP), dimension(:)  , allocatable :: wb                        ! Barycentric weights
      real(kind=RP), dimension(:,:), allocatable :: v                         ! Interpolation vector
      real(kind=RP), dimension(:,:), allocatable :: b                         ! Boundary vector
      real(kind=RP), dimension(:,:), allocatable :: D                         ! DG derivative matrix
      real(kind=RP), dimension(:,:), allocatable :: DT                        ! Trasposed DG derivative matrix
      real(kind=RP), dimension(:,:), allocatable :: hatD                      ! Weak form derivative matrix
      real(kind=RP), dimension(:,:), allocatable :: sharpD                    ! (Two times) the strong form derivative matrix
      contains
         procedure :: construct => ConstructNodalStorage
         procedure :: destruct  => DestructNodalStorage
         procedure :: lxi       => NodalStorage_getlxi
         procedure :: leta      => NodalStorage_getleta
         procedure :: lzeta     => NodalStorage_getlzeta
         procedure :: dlxi      => NodalStorage_getdlxi
         procedure :: dleta     => NodalStorage_getdleta
         procedure :: dlzeta    => NodalStorage_getdlzeta

   END TYPE NodalStorage
!      
!     ========
      CONTAINS 
!     ========
!
!////////////////////////////////////////////////////////////////////////
!
   subroutine ConstructNodalStorage( this, nodes, N)
      implicit none
      class(NodalStorage)      :: this       !<> Nodal storage being constructed
      integer, intent(in)      :: nodes
      integer, intent(in)      :: N          !<  Polynomial order
      !--------------------------------------
      integer            :: i,j
      real(kind=RP)      :: wb(0:N)
      integer, PARAMETER :: LEFT = 1, RIGHT = 2
      !--------------------------------------
      
      if (this % Constructed) return
      
      this % nodes = nodes
      this % N = N
      
      ALLOCATE( this % x    (0:N) )
      ALLOCATE( this % w    (0:N) )
      ALLOCATE( this % wb   (0:N) )
      ALLOCATE( this % v    (0:N,2) )
      ALLOCATE( this % b    (0:N,2) )
      ALLOCATE( this % D    (0:N,0:N) )
      ALLOCATE( this % DT   (0:N,0:N) )
      ALLOCATE( this % hatD (0:N,0:N) )
!
!     -----------------
!     Nodes and weights
!     -----------------
!
      select case (this % nodes)
         case (GAUSS)
            CALL GaussLegendreNodesAndWeights  ( N, this % x  , this % w )
         case (GAUSSLOBATTO)
            CALL LegendreLobattoNodesAndWeights( N, this % x  , this % w )
            allocate( this % sharpD(0:N,0:N) )
         case default
            print*, "Undefined nodes choice"
            errorMessage(STD_OUT)
            stop
      end select
!
!     -----------------
!     Derivative Matrix
!     -----------------
!
      CALL PolynomialDerivativeMatrix( N, this % x, this % D )
      DO j = 0, N
         DO i = 0, N
            this % DT  (i,j) = this % D (j,i)
            this % hatD(i,j) = this % DT(i,j) * this % w(j) / this % w(i)
         END DO
      END DO
      
!
!     --------------------------------------------------------------
!     Construct the strong form derivative matrices (Skew-Symmetric)
!     --------------------------------------------------------------
!
      if ( this % nodes .eq. GAUSSLOBATTO ) then
         this % sharpD = 2.0_RP * this % D
         this % sharpD(0,0) = 2.0_RP * this % D(0,0) + 1.0_RP / this % w(0)
         this % sharpD(N,N) = 2.0_RP * this % D(N,N) - 1.0_RP / this % w(N)
      end if
!
!     ---------------------
!     Interpolation vectors
!     ---------------------
!
      CALL BarycentricWeights( N, this % x, wb )
      
      CALL InterpolatingPolynomialVector(  1.0_RP, N, this % x, wb, this % b(:,RIGHT) )
      CALL InterpolatingPolynomialVector( -1.0_RP, N, this % x, wb, this % b(:,LEFT)  )
      
      this % wb = wb
      this % v  = this % b
      
      this % b(0:N,LEFT)  = this % b(0:N,LEFT) /this % w
      this % b(0:N,RIGHT) = this % b(0:N,RIGHT)/this % w
      
!
!     Set the nodal storage as constructed
!     ------------------------------------      
      this % Constructed = .TRUE.

   END SUBROUTINE ConstructNodalStorage
!
!////////////////////////////////////////////////////////////////////////
!
   SUBROUTINE DestructNodalStorage( this )
      IMPLICIT NONE
      CLASS(NodalStorage) :: this
!
!     Attempting to destruct a non-constructed nodal storage
!     ------------------------------------------------------
      if (.not. this % constructed ) return
!
!     Destruct otherwise
!     ------------------
      this % constructed = .FALSE.
      
      DEALLOCATE( this % x )
      DEALLOCATE( this % w  )
      DEALLOCATE( this % D  )
      DEALLOCATE( this % DT )
      DEALLOCATE( this % hatD)
      DEALLOCATE( this % v )
      DEALLOCATE( this % b )
      safedeallocate( this % sharpD )    !  This matrices are just generated for Gauss-Lobatto discretizations.

      END SUBROUTINE DestructNodalStorage
!
!////////////////////////////////////////////////////////////////////////
!
      function NodalStorage_getlxi(self, xi)
         implicit none
         class(NodalStorage), intent(in)  :: self
         real(kind=RP),       intent(in)  :: xi
         real(kind=RP)                    :: NodalStorage_getlxi(0:self % Nx)

         call InterpolatingPolynomialVector(xi , self % Nx , self % xi , self % wbx , NodalStorage_getlxi)

      end function NodalStorage_getlxi

      function NodalStorage_getleta(self, eta)
         implicit none
         class(NodalStorage), intent(in)  :: self
         real(kind=RP),       intent(in)  :: eta
         real(kind=RP)                    :: NodalStorage_getleta(0:self % Ny)

         call InterpolatingPolynomialVector(eta , self % Ny , self % eta , self % wby , NodalStorage_getleta)

      end function NodalStorage_getleta

      function NodalStorage_getlzeta(self, zeta)
         implicit none
         class(NodalStorage), intent(in)  :: self
         real(kind=RP),       intent(in)  :: zeta
         real(kind=RP)                    :: NodalStorage_getlzeta(0:self % Nz)

         call InterpolatingPolynomialVector(zeta , self % Nz , self % zeta , self % wbz , NodalStorage_getlzeta)

      end function NodalStorage_getlzeta

      function NodalStorage_getdlxi(self, xi)
         implicit none
         class(NodalStorage), intent(in)  :: self
         real(kind=RP),       intent(in)  :: xi
         real(kind=RP)                    :: NodalStorage_getdlxi(0:self % Nx)
!
!        ---------------
!        Local variables
!        ---------------
!
         integer  :: i

         do i = 0 , self % Nx
            NodalStorage_getdlxi(i) = EvaluateLagrangePolyDerivative( i, xi, self % Nx , self % xi)
         end do

      end function NodalStorage_getdlxi

      function NodalStorage_getdleta(self, eta)
         implicit none
         class(NodalStorage), intent(in)  :: self
         real(kind=RP),       intent(in)  :: eta
         real(kind=RP)                    :: NodalStorage_getdleta(0:self % Ny)
!
!        ---------------
!        Local variables
!        ---------------
!
         integer  :: i

         do i = 0 , self % Ny
            NodalStorage_getdleta(i) = EvaluateLagrangePolyDerivative( i, eta, self % Ny , self % eta)
         end do

      end function NodalStorage_getdleta

      function NodalStorage_getdlzeta(self, zeta)
         implicit none
         class(NodalStorage), intent(in)  :: self
         real(kind=RP),       intent(in)  :: zeta
         real(kind=RP)                    :: NodalStorage_getdlzeta(0:self % Nz)
!
!        ---------------
!        Local variables
!        ---------------
!
         integer  :: i

         do i = 0 , self % Nz
            NodalStorage_getdlzeta(i) = EvaluateLagrangePolyDerivative( i, zeta, self % Nz , self % zeta)
         end do

      end function NodalStorage_getdlzeta

END Module NodalStorageClass

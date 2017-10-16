!
!//////////////////////////////////////////////////////
!
!   @File:    ProlongMeshAndSolution.f90
!   @Author:  Juan Manzanero (juan.manzanero@upm.es)
!   @Created: Fri Oct 13 11:46:47 2017
!   @Last revision date:
!   @Last revision author:
!   @Last revision commit:
!
!//////////////////////////////////////////////////////
!
module ProlongMeshAndSolution
   use SMConstants
   use NodalStorageClass

   private
   public   ProlongMeshToGaussPoints, ProlongSolutionToGaussPoints



   contains
      subroutine ProlongMeshToGaussPoints(e,spAM,spAout)
!
!        *************************************************************************
!
!              The code arrives to this subroutine if any Nmesh != Nout. This
!           needs the mesh coordinates to be extrapolated to the solution order.
!           This is not a major issue for straight sided element.
!
!           For curved elements, one might extend the order just evaluating the
!           mapping at the new set of Gauss points, but to reduce the order, 
!           it is required that the mapping is evaluated at a new set of 
!           Chebyshev-Lobatto points, and then evaluated again to Gauss points.
!           Just for safety, all elements are traduced to Chebyshev points first,
!           and then to Gauss points. This could be avoided in the future.
!
!        *************************************************************************
!
         use TransfiniteMapClass
         use MappedGeometryClass
         use Storage
         implicit none
         type(Element_t)                 :: e
         type(NodalStorage), intent(in)  :: spAM
         type(NodalStorage), intent(in)  :: spAout
!
!        ---------------
!        Local variables
!        ---------------
!                              ////////////////////////////////////////
!                              // Mesh mapping prolongation to faces //
!                              ////////////////////////////////////////
         real(kind=RP)      :: face1Original(1:3, 0:e % Nmesh(1), 0:e % Nmesh(3))
         real(kind=RP)      :: face2Original(1:3, 0:e % Nmesh(1), 0:e % Nmesh(3))
         real(kind=RP)      :: face3Original(1:3, 0:e % Nmesh(1), 0:e % Nmesh(2))
         real(kind=RP)      :: face4Original(1:3, 0:e % Nmesh(2), 0:e % Nmesh(3))
         real(kind=RP)      :: face5Original(1:3, 0:e % Nmesh(1), 0:e % Nmesh(2))
         real(kind=RP)      :: face6Original(1:3, 0:e % Nmesh(2), 0:e % Nmesh(3)) 
!                              /////////////////////////////////////////
!                              // Chebyshev-Lobatto face interpolants //
!                              /////////////////////////////////////////
         real(kind=RP)      :: xiCL   (0:e % Nout(1)) 
         real(kind=RP)      :: etaCL  (0:e % Nout(2)) 
         real(kind=RP)      :: zetaCL (0:e % Nout(3)) 
         real(kind=RP)      :: face1CL(1:3, 0:e % Nout(1), 0:e % Nout(3))
         real(kind=RP)      :: face2CL(1:3, 0:e % Nout(1), 0:e % Nout(3))
         real(kind=RP)      :: face3CL(1:3, 0:e % Nout(1), 0:e % Nout(2))
         real(kind=RP)      :: face4CL(1:3, 0:e % Nout(2), 0:e % Nout(3))
         real(kind=RP)      :: face5CL(1:3, 0:e % Nout(1), 0:e % Nout(2))
         real(kind=RP)      :: face6CL(1:3, 0:e % Nout(2), 0:e % Nout(3))
!                              /////////////////////////////
!                              // Define the new element //
!                              /////////////////////////////
         type(FacePatch)         :: facePatches(6)
         type(TransfiniteHexMap) :: hexMap
         integer                 :: i, j, k
         real(kind=RP)           :: localCoords(3)
!
!        Get the faces coordinates from the mapping
!        ------------------------------------------
         call InterpolateFaces(e % Nmesh,spAM,e % x,face1Original,&
                                                    face2Original,&   
                                                    face3Original,&   
                                                    face4Original,&   
                                                    face5Original,&   
                                                    face6Original  )
!
!        Construct face patches
!        ----------------------
         call facePatches(1) % Construct( spAM % xi , spAM % zeta, face1Original )
         call facePatches(2) % Construct( spAM % xi , spAM % zeta, face2Original )
         call facePatches(3) % Construct( spAM % xi , spAM % eta , face3Original )
         call facePatches(4) % Construct( spAM % eta, spAM % zeta, face4Original )
         call facePatches(5) % Construct( spAM % xi , spAM % eta , face5Original )
         call facePatches(6) % Construct( spAM % eta, spAM % zeta, face6Original )
!
!        Construct the interpolants based on Chebyshev-Lobatto points
!        ------------------------------------------------------------
         xiCL   = RESHAPE( (/ ( -cos((i)*PI/(e % Nout(1))),i=0, e % Nout(1)) /), (/ e % Nout(1) + 1 /) )
         etaCL  = RESHAPE( (/ ( -cos((i)*PI/(e % Nout(2))),i=0, e % Nout(2)) /), (/ e % Nout(2) + 1 /) )
         zetaCL = RESHAPE( (/ ( -cos((i)*PI/(e % Nout(3))),i=0, e % Nout(3)) /), (/ e % Nout(3) + 1 /) )

         call ProjectFaceToNewPoints(facePatches(1), e % Nout(1), xiCL , e % Nout(3), zetaCL, face1CL)
         call ProjectFaceToNewPoints(facePatches(2), e % Nout(1), xiCL , e % Nout(3), zetaCL, face2CL)
         call ProjectFaceToNewPoints(facePatches(3), e % Nout(1), xiCL , e % Nout(2), etaCL , face3CL)
         call ProjectFaceToNewPoints(facePatches(4), e % Nout(2), etaCL, e % Nout(3), zetaCL, face4CL)
         call ProjectFaceToNewPoints(facePatches(5), e % Nout(1), xiCL , e % Nout(2), etaCL , face5CL)
         call ProjectFaceToNewPoints(facePatches(6), e % Nout(2), etaCL, e % Nout(3), zetaCL, face6CL)
!
!        Destruct face patches
!        ---------------------
         call facePatches(1) % Destruct()
         call facePatches(2) % Destruct()
         call facePatches(3) % Destruct()
         call facePatches(4) % Destruct()
         call facePatches(5) % Destruct()
         call facePatches(6) % Destruct()
!
!        Construct the new Chebyshev-Lobatto face patches
!        ------------------------------------------------
         call facePatches(1) % Construct( xiCL , zetaCL, face1CL )
         call facePatches(2) % Construct( xiCL , zetaCL, face2CL )
         call facePatches(3) % Construct( xiCL , etaCL , face3CL )
         call facePatches(4) % Construct( etaCL, zetaCL, face4CL )
         call facePatches(5) % Construct( xiCL , etaCL , face5CL )
         call facePatches(6) % Construct( etaCL, zetaCL, face6CL )
!
!        Construct the geometry mapper
!        -----------------------------
         call hexMap % constructWithFaces( facePatches )
!
!        Construct the mapping interpolant
!        ---------------------------------
         do k = 0, e % Nout(3)    ; do j = 0, e % Nout(2)  ; do i = 0, e % Nout(1)
            localCoords = (/ spAout % xi(i), spAout % eta(j), spAout % zeta(k) /)
            e % xOut(:,i,j,k) = hexMap % transfiniteMapAt(localCoords) 
         end do               ; end do             ; end do
!
!        Destruct face patches
!        ---------------------
         call facePatches(1) % Destruct()
         call facePatches(2) % Destruct()
         call facePatches(3) % Destruct()
         call facePatches(4) % Destruct()
         call facePatches(5) % Destruct()
         call facePatches(6) % Destruct()
         call hexMap         % Destruct()

      end subroutine ProlongMeshToGaussPoints

      subroutine ProlongSolutionToGaussPoints(NEQ,Nsol,Q,Nout,Qout,Tx,Ty,Tz)
         implicit none
         integer,            intent(in)  :: NEQ
         integer,            intent(in)  :: Nsol(3)
         real(kind=RP),      intent(in)  :: Q(0:Nsol(1),0:Nsol(2),0:Nsol(3),1:NEQ)
         integer,            intent(in)  :: Nout(3)
         real(kind=RP),      intent(out) :: Qout(0:Nout(1),0:Nout(2),0:Nout(3),1:NEQ)
         real(kind=RP),      intent(in)  :: Tx(0:Nout(1),0:Nsol(1))
         real(kind=RP),      intent(in)  :: Ty(0:Nout(2),0:Nsol(2))
         real(kind=RP),      intent(in)  :: Tz(0:Nout(3),0:Nsol(3))
!
!        ---------------
!        Local variables
!        ---------------
!
         integer  :: i, j, k, l, m, n, iVar

         Qout = 0.0_RP

         do iVar = 1, NEQ
            do n = 0, Nsol(3) ; do m = 0, Nsol(2) ; do l = 0, Nsol(1)
               do k = 0, Nout(3) ; do j = 0, Nout(2) ; do i = 0, Nout(1)
                  Qout(i,j,k,iVar) = Qout(i,j,k,iVar) + Q(l,m,n,iVar) * Tx(i,l) * Ty(j,m) * Tz(k,n)
               end do            ; end do            ; end do
            end do            ; end do            ; end do
         end do
         

      end subroutine ProlongSolutionToGaussPoints
!
!/////////////////////////////////////////////////////////////////////////////////////////
!
!        Auxiliar subroutines
!        --------------------
!
!/////////////////////////////////////////////////////////////////////////////////////////
!
      subroutine InterpolateFaces(N,spA,x,face1,face2,face3,face4,face5,face6)
!
!        ****************************************************************
!
!              This subroutine obtains the faces coordinates from the
!           mapping interpolant x.
!     
!        ****************************************************************
!        
         implicit none
         integer,            intent(in)  :: N(3)
         type(NodalStorage), intent(in)  :: spA
         real(kind=RP),      intent(in)  :: x(1:3,0:N(1),0:N(2),0:N(3))
         real(kind=RP),      intent(out) :: face1(1:3,0:N(1),0:N(3))
         real(kind=RP),      intent(out) :: face2(1:3,0:N(1),0:N(3))
         real(kind=RP),      intent(out) :: face3(1:3,0:N(1),0:N(2))
         real(kind=RP),      intent(out) :: face4(1:3,0:N(2),0:N(3))
         real(kind=RP),      intent(out) :: face5(1:3,0:N(1),0:N(2))
         real(kind=RP),      intent(out) :: face6(1:3,0:N(2),0:N(3))
!
!        ---------------
!        Local variables
!        ---------------
!
         integer  :: i, j, k
!
!        faces (1,2) - eta direction
!        ---------------------------
         face1 = 0.0_RP
         face2 = 0.0_RP

         do k = 0, N(3) ; do j = 0, N(2) ; do i = 0, N(1)
            face1(:,i,k) = face1(:,i,k) + x(:,i,j,k) * spA % vy(j,1)
            face2(:,i,k) = face2(:,i,k) + x(:,i,j,k) * spA % vy(j,2)
         end do             ; end do             ; end do
!
!        faces (3,5) - zeta direction
!        ----------------------------
         face3 = 0.0_RP
         face5 = 0.0_RP

         do k = 0, N(3) ; do j = 0, N(2) ; do i = 0, N(1)
            face3(:,i,j) = face3(:,i,j) + x(:,i,j,k) * spA % vz(k,1)
            face5(:,i,j) = face5(:,i,j) + x(:,i,j,k) * spA % vz(k,2)
         end do             ; end do             ; end do
!
!        faces (4,6) - xi direction
!        --------------------------
         face4 = 0.0_RP
         face6 = 0.0_RP

         do k = 0, N(3) ; do j = 0, N(2) ; do i = 0, N(1)
            face4(:,j,k) = face4(:,j,k) + x(:,i,j,k) * spA % vx(i,1)
            face6(:,j,k) = face6(:,j,k) + x(:,i,j,k) * spA % vx(i,2)
         end do             ; end do             ; end do

      end subroutine InterpolateFaces

      subroutine ProjectFaceToNewPoints(patch,Nx,xi,Ny,eta,facecoords)
         use MappedGeometryClass
         implicit none
         type(FacePatch),  intent(in)     :: patch
         integer,          intent(in)     :: Nx
         real(kind=RP),    intent(in)     :: xi(0:Nx)
         integer,          intent(in)     :: Ny
         real(kind=RP),    intent(in)     :: eta(0:Ny)
         real(kind=RP),    intent(out)    :: faceCoords(1:3,0:Nx,0:Ny)
!
!        ---------------
!        Local variables
!        ---------------
!
         integer     :: i, j
         real(kind=RP)  :: localCoords(2)
               
         do j = 0, Ny ; do i = 0, Nx
            localCoords = (/ xi(i), eta(j) /)
            call ComputeFacePoint(patch, localCoords, faceCoords(:,i,j) )
         end do       ; end do

      end subroutine ProjectFaceToNewPoints

end module ProlongMeshAndSolution

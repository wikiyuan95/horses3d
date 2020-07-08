!
!//////////////////////////////////////////////////////
!
!   @File:    ReadMeshFile.f90
!   @Author:  Andrés Rueda (am.rueda@upm.es)
!   @Created: Sun Apr 27 12:57:00 2017
!   @Last revision date: Wed Jul 17 11:52:46 2019
!   @Last revision author: Andrés Rueda (am.rueda@upm.es)
!   @Last revision commit: 67e046253a62f0e80d1892308486ec5aa1160e53
!
!//////////////////////////////////////////////////////
!
#include "Includes.h"
module ReadMeshFile
   use SMConstants
   use Read_HDF5Mesh_HOPR
   use Read_SpecMesh
   use HexMeshClass
   use MeshTypes           , only: SPECMESH, HOPRMESH, HMESH_INTERIOR, HMESH_BOUNDARY, HMESH_MPI
   use FileReadingUtilities, only: getFileExtension
   implicit none

   private
   public constructMeshFromFile, NumOfElemsFromMeshFile, MeshFileType

contains
   subroutine constructMeshFromFile( self, fileName, nodes, Nx, Ny, Nz, MeshInnerCurves , dir2D, success )
      implicit none
      !---------------------------------------------------------------
      type(HexMesh)                       :: self
      CHARACTER(LEN=*)                    :: fileName
      integer                             :: nodes
      INTEGER                             :: Nx(:), Ny(:), Nz(:)     !<  Polynomial orders for all the elements
      logical                             :: MeshInnerCurves         !<  Describe inner curved surfaces? (only for hdf5)
      integer                             :: dir2D
      LOGICAL           , intent(out)     :: success
      !---------------------------------------------------------------
      character(len=LINE_LENGTH) :: ext
      integer                    :: nelem
      integer                    :: eID, fID
      integer                    :: no_interior_faces, no_boundary_faces, no_mpi_faces
      integer                    :: no_sequential_elems, no_mpi_elems
      integer                    :: aux_array(1:3)
      !---------------------------------------------------------------
      
      ext = getFileExtension(trim(filename))
      
      if (trim(ext)=='h5') then
         call ConstructMesh_FromHDF5File_( self, fileName, nodes, Nx, Ny, Nz, MeshInnerCurves , dir2D, success )
      elseif (trim(ext)=='mesh') then
         call ConstructMesh_FromSpecMeshFile_( self, fileName, nodes, Nx, Ny, Nz, dir2D, success )
      else
         ERROR STOP 'Mesh file extension not recognized.'
      end if
      
      self % NDOF = 0
      do eID=1, self % no_of_elements
         self % NDOF = self % NDOF + product(self % elements(eID) % Nxyz + 1)
      end do
!
!     ******************************************************************************
!     Create three arrays that contain the fIDs of interior, mpi, and boundary faces
!     ******************************************************************************
!
      self % no_of_faces = size(self % faces)

      no_interior_faces = 0
      no_boundary_faces = 0
      no_mpi_faces      = 0

      aux_array = 0
      do fID = 1, self % no_of_faces
         aux_array(self % faces(fID) % faceType) = aux_array(self % faces(fID) % faceType) + 1
      end do

      no_interior_faces = aux_array(HMESH_INTERIOR)
      no_mpi_faces      = aux_array(HMESH_MPI)
      no_boundary_faces = aux_array(HMESH_BOUNDARY)

      allocate(self % faces_interior(no_interior_faces))
      allocate(self % faces_mpi     (no_mpi_faces     ))
      allocate(self % faces_boundary(no_boundary_faces))

      no_interior_faces = 0
      no_boundary_faces = 0
      no_mpi_faces      = 0
      do fID = 1, self % no_of_faces
         select case (self % faces(fID) % faceType)
         case(HMESH_INTERIOR)
            no_interior_faces = no_interior_faces + 1
            self % faces_interior(no_interior_faces) = fID

         case(HMESH_MPI)
            no_mpi_faces = no_mpi_faces + 1
            self % faces_mpi(no_mpi_faces) = fID

         case(HMESH_BOUNDARY)
            no_boundary_faces = no_boundary_faces + 1
            self % faces_boundary(no_boundary_faces) = fID

         end select
      end do

      no_sequential_elems = 0
      no_mpi_elems = 0

      do eID = 1, self % no_of_elements
         if (self % elements(eID) % hasSharedFaces) then
            no_mpi_elems = no_mpi_elems + 1 
         else
            no_sequential_elems = no_sequential_elems + 1 
         end if
      end do

      allocate(self % elements_sequential(no_sequential_elems))
      allocate(self % elements_mpi(no_mpi_elems))
      
      no_sequential_elems = 0
      no_mpi_elems = 0

      do eID = 1, self % no_of_elements
         if (self % elements(eID) % hasSharedFaces) then
            no_mpi_elems = no_mpi_elems + 1 
            self % elements_mpi(no_mpi_elems) = eID
         else
            no_sequential_elems = no_sequential_elems + 1 
            self % elements_sequential(no_sequential_elems) = eID
         end if
      end do

   end subroutine constructMeshFromFile
!
!///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
!
   function NumOfElemsFromMeshFile(fileName) result(nelem)
      implicit none
      !---------------------------------------------------------------
      CHARACTER(LEN=*)   :: fileName
      integer            :: nelem
      !---------------------------------------------------------------
      character(len=LINE_LENGTH) :: ext
      !---------------------------------------------------------------
      
      ext = getFileExtension(trim(filename))
      
      if (trim(ext)=='h5') then
         nelem = NumOfElems_HDF5( fileName )
      elseif (trim(ext)=='mesh') then
         nelem = NumOfElems_SpecMesh( fileName )
      else
         ERROR STOP 'Mesh file extension not recognized.'
      end if
      
   end function NumOfElemsFromMeshFile  
!
!///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
!
   integer function MeshFileType(fileName)
      implicit none
      !-arguments----------------------------------------------------
      CHARACTER(LEN=*)   :: fileName
      !-local-variables----------------------------------------------
      character(len=LINE_LENGTH) :: ext
      !--------------------------------------------------------------
      ext = getFileExtension(trim(filename))
      
      if (trim(ext)=='h5') then
         MeshFileType = HOPRMESH
      elseif (trim(ext)=='mesh') then
         MeshFileType = SPECMESH
      else
         ERROR STOP 'Mesh file extension not recognized.'
      end if
      
   end function MeshFileType
end module ReadMeshFile
